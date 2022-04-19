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
    struct Balances {
        uint128 art; // Debt amount
        uint128 ink; // Collateral amount
    }
}

interface ILadle {
    function pour(bytes12 vaultId_, address to, int128 ink, int128 art) external payable;
    function repayFromLadle(bytes12 vaultId_, address to) external payable returns (uint256 repaid);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function cauldron() external view returns (ICauldron);
}

interface ICauldron {
    function balances(bytes12 vault) external view returns (DataTypes.Balances memory);
}

contract YieldSpaceAMO is Owned {
    /* =========== STATE VARIABLES =========== */
    
    // Frax
    IFrax private immutable FRAX;
    IFraxAMOMinter private amo_minter;
    address public timelock_address;
    address public custodian_address;

    // Yield Protocol
    IFYToken private immutable fyFRAX;
    ILadle private immutable ladle;
    IPool private immutable pool;
    ICauldron private immutable cauldron;
    address public immutable fraxJoin;
    bytes12 public immutable vaultId; /// @notice The AMO's debt & collateral record

    // AMO
    uint256 public currentAMOmintedFRAX; /// @notice The amount of FRAX tokens minted by the AMO
    uint256 public currentAMOmintedFyFRAX;
    uint256 public fraxLiquidityAdded; /// @notice The amount FRAX added to LP
    uint256 public fyFraxLiquidityAdded;

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
        fyFRAX = IFYToken(pool.fyToken());
        cauldron = ICauldron(ladle.cauldron());
        fraxJoin = _yield_frax_join;

        currentAMOmintedFRAX = 0;
        currentAMOmintedFyFRAX = 0;
        fraxLiquidityAdded = 0;

        (vaultId,) = ladle.build(_seriesId, "0x3138", 0); //0x3138 is IlkID for Frax
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
    // /// @notice returns current rate on Frax debt
    // function getRate() public view returns (uint256) { //TODO Name better & figure out functionality
    //     return (circulatingAMOMintedFyFrax() - currentRaisedFrax()) / (currentRaisedFrax() * /*timeremaining*/; //TODO pos/neg
    // }

    function showAllocations() public view returns (uint256[6] memory return_arr) {
        uint256 frax_in_contract = FRAX.balanceOf(address(this));
        uint256 frax_as_collateral = uint256(cauldron.balances(vaultId).ink);
        uint256 frax_in_LP = FRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
        uint256 fyFrax_in_contract = fyFRAX.balanceOf(address(this));
        uint256 fyFrax_in_LP = fyFRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
        uint256 LP_owned = pool.balanceOf(address(this));
        return [
            frax_in_contract,       // [0] Unallocated Frax
            frax_as_collateral,     // [1] Frax being used as collateral to borrow fyFrax                     
            frax_in_LP,             // [2] The Frax our LP tokens can lay claim to
            fyFrax_in_contract,     // [3] fyFrax sitting in AMO, should be 0
            fyFrax_in_LP,           // [4] fyFrax our LP can claim
            LP_owned                // [5] number of LP tokens
        ];
    }

    function currFraxInAMOLP() public view returns (uint256) {
        uint256[6] memory arr = showAllocations();
        return arr[2];
        // return FRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }
    
    function currFyFraxInAMOLP() public view returns (uint256) {
        uint256[6] memory arr = showAllocations();
        return arr[4];
        // return fyFRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }

    /// @return raisedFrax The Frax fundraised by the AMO
    /// @return isNegative True if currFrax should be flipped in sign, ie the LP has less Frax than it began with
    function currentRaisedFrax() public view returns (uint256 raisedFrax, bool isNegative) {
        uint256 fraxInLP = currFraxInAMOLP();
        if (fraxInLP >= fraxLiquidityAdded) { //Frax has entered the AMO's LP
            return (fraxInLP - fraxLiquidityAdded, false);
        } else { //Frax has left the AMO's LP
            return (fraxLiquidityAdded - fraxInLP, true);
        }
    }

    /// @notice returns the current amount of FRAX that the protocol must pay out on maturity of circulating fyFRAX in the open market
    /// @notice signed return value
    function circulatingAMOMintedFyFrax() public view returns (uint256 circulatingFyFrax, bool isNegative) {
        uint256 fyFraxInLP = currFyFraxInAMOLP();
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
        uint256 sum = currentAMOmintedFRAX * (FRAX.global_collateral_ratio() / 1000000); //TODO Make these precision constants
        sum = raisedFraxisNegative ? sum - raisedFrax : sum + raisedFrax; 
        sum = circFyFraxisNegative ? sum + circFyFrax : sum - circFyFrax;
        return sum;
        //Normal conditions: return currentAMOmintedFRAX * (FRAX.global_collateral_ratio() / 1000000) + currentRaisedFrax() - circFyFrax;
    }

    // function dollarBalances() public view returns (uint256 frax_val_e18, uint256 collat_val_e18) {
    //     uint256[6] arr = showAllocations();
    //     //TODO figure this out with Dennis
    // }
    
    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice mint fyFrax using FRAX as collateral 1:1 Frax to fyFrax
    function mintFyFrax(uint256 _amount) public view onlyByOwnGov returns (uint256) { //Likely 
        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        uint256 fyFraxAmount = _amount;
        uint256 fraxAmount = _amount; //1:1 collateral
        FRAX.transfer(fraxJoin, fraxAmount);
        ladle.pour(vaultId, address(this), fraxAmount, fyFraxAmount);
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax() public view onlyByOwnGov returns (uint256) { 
        //Transfer fyFRAX to the fyFRAX contract, repay debt, and withdraw FRAX collateral.
        uint256 fyFraxAmount = fyFRAX.balanceOf(address(this));
        uint256 fraxAmount = fyFraxAmount;
        fyFRAX.transfer(address(fyFRAX), fyFraxAmount);
        ladle.pour(vaultId, address(this), -fraxAmount, -fyFraxAmount);
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates 
    function increaseRates(uint256 _fraxAmount, uint256 _minFraxReceived) public view onlyByOwnGov returns (uint256) {
        //Mint fyFRAX into the pool, and sell it.
        uint256 fyFraxAmount = _fraxAmount;
        FRAX.transfer(fraxJoin, _fraxAmount);
        ladle.pour(vaultId, address(pool), _fraxAmount, fyFraxAmount);
        pool.sellFYToken(address(this), _minFraxReceived);
    }

    /// @notice buy fyFrax from the AMO and burn it to push down rates
    function decreaseRates(uint256 _fraxAmount, uint256 _minFyFraxReceived) public view onlyByOwnGov returns (uint256) {
        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(address(pool), _fraxAmount);
        uint256 fyFraxReceived = pool.sellBase(address(fyFRAX), _minFyFraxReceived);
        uint256 fraxCollat = fyFraxReceived;
        ladle.pour(vaultId, address(this), -fraxCollat, -fyFraxReceived);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(uint256 _fraxAmount, uint256 _fyFraxAmount, uint256 _minRatio, uint256 _maxRatio) public view onlyByOwnGov returns (uint256) {
        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        FRAX.transfer(fraxJoin, _fyFraxAmount);
        FRAX.transfer(address(pool), _fraxAmount);
        ladle.pour(vaultId, address(pool), _fyFraxAmount, _fyFraxAmount);
        pool.mint(address(this), address(this), _minRatio, _maxRatio); //Second param receives remainder
    }

    /// @notice remove liquidity and burn fyTokens
    function removeLiquidityFromAMM(uint256 _poolAmount, uint256 _minRatio, uint256 _maxRatio) public view onlyByOwnGov returns (uint256) {
        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the Ladle.
        //Instruct the Ladle to repay as much debt as fyFRAX it received, and withdraw the same amount of collateral.
        pool.transfer(address(pool), _poolAmount);
        pool.burn(address(this), address(ladle), _minRatio, _maxRatio);
        ladle.repayFromLadle(vaultId, address(this));
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
