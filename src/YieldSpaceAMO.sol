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

interface ILadle {
    function pour(bytes12 vaultId_, address to, int128 ink, int128 art) external payable;
    function repayFromLadle(bytes12 vaultId_, address to) external payable returns (uint256 repaid);
}

contract YieldSpaceAMO is Owned {
    /* =========== STATE VARIABLES =========== */
    
    // Frax
    IFrax private immutable FRAX;
    IFraxAMOMinter private amo_minter;
    address public timelock_address;
    address public custodian_address;

    // Yield Protocol
    IFyToken private immutable fyFRAX;
    ILadle private immutable ladle;
    IPool private immutable pool;
    address public immutable fraxJoin;

    // AMO
    uint256 public currentAMOmintedFRAX; /// @notice The amount of FRAX tokens minted by the AMO
    uint256 public currentAMOmintedFyFRAX;
    uint256 public fraxLiquidityAdded; /// @notice The amount FRAX added to LP
    uint256 public fyFraxLiquidityAdded;
    bytes12 public vaultId; /// @notice The AMO's debt & collateral record

    /* ============= CONSTRUCTOR ============= */
    constructor (
        address _owner_address,
        address _amo_minter_address,
        address _yield_ladle,
        address _target_fyFrax_pool,
        address _yield_frax_join
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
    function getRate() public view returns (uint256) { //TODO Name better
    }

    /// @notice returns the Frax fundraised by the AMM
    /// @note signed return value
    function currentRaisedFrax() public view returns (int256) {
        return /*AmountOfFraxInLPPosition*/ - fraxLiquidityAdded; //TODO
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    /// (all AMOs have this function)
    function collatDollarBalance() public view returns (uint256) {
        return currentAMOmintedFRAX * FRAX.global_collateral_ratio() + currentRaisedFrax() - circulatingAMOMintedFyFrax();
    }

    /// @notice returns the current amount of FRAX that the protocol must pay out on maturity of circulating fyFRAX in the open market
    function circulatingAMOMintedFyFrax() public view returns (uint256) {
        uint numLPtokens = pool.balanceOf(address(this));

        // return numTokensMintedToAMO - %oftheLPthatWeControl*numberofFyTokensInPool;
    }

    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice mint fyFrax using FRAX as collateral
    function mintFyFrax(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        //frax.transfer(fraxJoin, fraxAmount);
        //ladle.pour(vaultId, fyFraxReceiver, fraxAmount, fyFraxAmount);
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
        //Transfer fyFRAX to the fyFRAX contract, repay debt, and withdraw FRAX collateral.
        //fyFrax.transfer(fyFraxContract, fyFraxAmount);
        //ladle.pour(vaultId, fraxRceiver, -fraxAmount, -fyFraxAmount);
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates
    function increaseRates(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
        //Mint fyFRAX into the pool, and sell it.
        //frax.transfer(fraxJoin, fraxAmount);
        //ladle.pour(vaultId, fraxPool, fraxAmount, fyFraxAmount);
        //pool.sellFyToken(fraxReceiver, minimumFraxReceived);
    }

    /// @notice buy fyFrax from the AMO to push down rates //TODO and burn???
    function decreaseRates(uint256 _frax_amount) public view onlyByOwnGovCust returns (uint256) {
        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        //frax.transfer(pool, fraxAmount);
        //pool.sellBase(fyFraxContract, minimumFyFraxReceived);
        //ladle.pour(vaultId, fraxReceiver, -fraxAmount, -fyFraxAmount);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(uint256 _frax_amount uint256 _fyFrax_amount) public view onlyByOwnGovCust returns (uint256) {
        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        //TODO: Set vaultId
        //frax.transfer(fraxJoin, fyFraxAmount);
        //frax.transfer(pool, fraxAmount);
        //ladle.pour(vaultId, fraxPool, fyFraxAmount, fyFraxAmount);
        //pool.mint(lpReceiver, fraxRemainderReceiver, minRatio, maxRatio);
    }

    /// @notice remove liquidity and burn fyTokens //TODO why burn???
    function removeLiquidityFromAMM(uint256 _poolAmount) public view onlyByOwnGovCust returns (uint256) {
        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the Ladle. Instruct the Ladle to repay as much debt as fyFRAX it received, and withdraw the same amount of collateral.
        //pool.transfer(pool, poolAmount);
        //pool.burn(fraxReceiver, ladle, minRatio, maxRatio);
        //ladle.repayFromLadle(vaultId, fraxReceiver);
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
