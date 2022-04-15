// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================== YieldSpaceAMO ===========================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Jack Corddry: https://github.com/corddry
// Sam Kazemian: https://github.com/samkazemian
// Dennis: https://github.com/denett

import "./Frax/IFrax.sol";
import "./Frax/IFraxAmoMinter.sol";
import "./utils/Owned.sol";
import "./Yield/IFYToken.sol";
import "./Yield/IPool.sol";

library DataTypes {
    struct Vault {
        address owner;
        bytes6 seriesId; // Each vault is related to only one series, which also determines the underlying.
        bytes6 ilkId; // Asset accepted as collateral
    }
}

interface ILadle {
    function pour(bytes12 vaultId_, address to, int128 ink, int128 art) external payable;
    function repayFromLadle(bytes12 vaultId_, address to) external payable returns (uint256 repaid);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external virtual payable returns(bytes12, DataTypes.Vault memory);
}

contract YieldSpaceAMO is Owned {
    /* =========== STATE VARIABLES =========== */
    
    // Frax
    IFrax private immutable FRAX;
    IFraxAMOMinter private amo_minter;
    address public timelock_address;
    address public custodian_address;

    // Yield Protocol
    IFyToken private immutable fyFRAX; //TODO: clean up interface imports
    ILadle private immutable ladle;
    IPool private immutable pool;
    address public immutable fraxJoin;

    // AMO //TODO: update these numbers in the restricted functions
    uint256 public currentAMOmintedFRAX; /// @notice The amount of FRAX tokens minted by the AMO
    uint256 public currentAMOmintedFyFRAX;
    uint256 public fraxLiquidityAdded; /// @notice The amount FRAX added to LP
    uint256 public fyFraxLiquidityAdded;
    bytes12 public vaultId; /// @notice The AMO's debt & collateral record //TODO: immutable?

    /* ============= CONSTRUCTOR ============= */
    constructor (
        address _owner_address,
        address _amo_minter_address,
        address _yield_ladle,
        address _target_fyFrax_pool,
        address _yield_frax_join,
        bytes6 _seriesId
    ) Owned(_owner_address) {
        FRAX = IFrax(0x853d955aCEf822Db058eb8505911ED77F175b99e);
        amo_minter = IFraxAMOMinter(_amo_minter_address);
        timelock_address = amo_minter.timelock_address();

        ladle = ILadle (_yield_ladle);
        pool = IPool(_target_fyFrax_pool);
        fyFrax = IFyToken(pool.fyToken);
        fraxJoin = _yield_frax_join;

        currentAMOmintedFRAX = 0;
        currentAMOmintedFyFRAX = 0;
        fraxLiquidityAdded = 0;

        uint8 salt = keccak256(abi.encodePacked(_seriesId, "FRAXAMO"));
        (vaultId,,) = ladle.build(_seriesId, 0x3138, salt); //0x3138 is IlkID for Frax
    }

    /* ============== MODIFIERS ============== */
    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByMinter() {
        require(msg.sender == address(amo_minter), "Not minter");
        _;
    }

    /* ================ VIEWS ================ */
    /// @notice returns current rate on Frax debt
    function getRate() public view returns (uint256) { //TODO Name better & figure out functionality
    }

    function currFraxInAMOLP() public view returns (uint256) {
        return FRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }
    
    function currFyFraxInAMOLP() public view returns (uint256) {
        return fyFRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }

    /// @return The Frax fundraised by the AMO
    /// @return True if currFrax should be flipped in sign, ie the LP has less Frax than it began with
    function currentRaisedFrax() public view returns (uint256 raisedFrax, bool isNegative) {
        fraxInLP = currFraxInAMOLP();
        if (fraxInLP >= fraxLiquidityAdded) { //Frax has entered the AMO's LP
            return (fraxInLP - fraxLiquidityAdded, false);
        } else { //Frax has left the AMO's LP
            return (fraxLiquidityAdded - fraxInLP, true);
        }
    }

    /// @notice returns the current amount of FRAX that the protocol must pay out on maturity of circulating fyFRAX in the open market
    /// @notice signed return value
    function circulatingAMOMintedFyFrax() public view returns (uint256 circulatingFyFrax, bool isNegative) {
        fyFraxInLP = currFyFraxInAMOLP();
        if (fyFraxLiquidityAdded >= fyFraxInLP) { //AMO minted fyFrax has left the LP
            return (fyFraxLiquidityAdded - fyFraxInLP, false);
        } else { //non-AMO minted fyFrax has entered the LP
            return (fyFraxInLP - fyFraxLiquidityAdded, true);
        }
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    /// (necessary for all Frax AMOs have this function)
    function collatDollarBalance() public view returns (uint256) {
        (uint256 circFyFrax, bool circFyFraxisNegative) = circulatingAMOMintedFyFrax();
        (uint256 raisedFrax, bool raisedFraxisNegative) = currentRaisedFrax();
        uint256 sum = currentAMOmintedFRAX * (FRAX.global_collateral_ratio() / 1000000);
        sum = raisedFraxisNegative ? sum - raisedFrax : sum + raisedFrax; 
        sum = circFyFraxisNegative ? sum + circFyFrax : sum - circFyFrax;
        //Normal conditions: return currentAMOmintedFRAX * (FRAX.global_collateral_ratio() / 1000000) + currentRaisedFrax() - circFyFrax;
    }

    
    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice mint fyFrax using FRAX as collateral
    function mintFyFrax(uint256 _fraxAmount, address _to) public view onlyByOwnGov returns (uint256) { //TODO: unnecessary due to going straight to LP? & _to
        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        FRAX.transfer(fraxJoin, _fraxAmount);
        ladle.pour(vaultId, _to, fraxAmount, fyFraxAmount);
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax(uint256 _fyFraxAmount, address _to) public view onlyByOwnGov returns (uint256) { //TODO consider what _to should be
        //Transfer fyFRAX to the fyFRAX contract, repay debt, and withdraw FRAX collateral.
        fyFRAX.transfer(address(fyFRAX), _fyFraxAmount);
        ladle.pour(vaultId, _to, -fraxAmount, -fyFraxAmount);
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates //TODO what to do after & determine fraxReceiver
    function increaseRates(uint256 _fraxAmount) public view onlyByOwnGov returns (uint256) {
        //Mint fyFRAX into the pool, and sell it.
        FRAX.transfer(fraxJoin, _fraxAmount);
        ladle.pour(vaultId, fraxPool, _fraxAmount, fyFraxAmount); //TODO: second param, is 'art', (debt), ratio between FraxAmount (ink/collat) & fyFraxAmount depends on how we colalt
        pool.sellFyToken(fraxReceiver, minimumFraxReceived); //TODO: these params
    }

    /// @notice buy fyFrax from the AMO to push down rates //TODO what to do after & determine fyFraxReceiver
    function decreaseRates(uint256 _fraxAmount) public view onlyByOwnGov returns (uint256) {
        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(pool, _fraxAmount);
        pool.sellBase(address(fyFrax), minimumFyFraxReceived); //TODO: second param
        ladle.pour(vaultId, fraxReceiver, -_fraxAmount, -fyFraxAmount); //TODO: fyFraxAmount
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(uint256 _fraxAmount, uint256 _fyFraxAmount) public view onlyByOwnGov returns (uint256) {
        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        FRAX.transfer(fraxJoin, fyFraxAmount);
        FRAX.transfer(pool, _fraxAmount);
        ladle.pour(vaultId, fraxPool, _fyFraxAmount, _fyFraxAmount); //TODO: amount params
        pool.mint(lpReceiver, fraxRemainderReceiver, minRatio, maxRatio); //TODO: remainderReceiver & ratios
    }

    /// @notice remove liquidity and burn fyTokens //TODO why burn???
    function removeLiquidityFromAMM(uint256 _poolAmount) public view onlyByOwnGov returns (uint256) {
        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the Ladle. Instruct the Ladle to repay as much debt as fyFRAX it received, and withdraw the same amount of collateral.
        pool.transfer(address(pool), _poolAmount);
        pool.burn(fraxReceiver, ladle, minRatio, maxRatio); //TODO: receiver & ratio
        ladle.repayFromLadle(vaultId, fraxReceiver); //TODO: receiver
    }

    /* === RESTRICTED GOVERNANCE FUNCTIONS === */
    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IFraxAMOMinter(_amo_minter_address);

        // Get the timelock addresses from the minter
        timelock_address = amo_minter.timelock_address();

        // Make sure the new addresses are not address(0)
        require(timelock_address != address(0), "Invalid timelock");
    }

    /// @notice generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        return (success, result);
    }

    /* ================ EVENTS =============== */
    //TODO What events do we want?
}
