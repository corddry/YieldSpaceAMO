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
import "./Frax/IFraxAMOMinter.sol";
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
    struct Series {
        IFYToken fyToken; // Redeemable token for the series.
        bytes6 baseId; // Asset received on redemption.
        uint32 maturity; // Unix time at which redemption becomes possible.
    }
}

library SafeCast {
    function u128(uint256 amount) internal pure returns(uint128){
        require (amount < type(uint128).max, "casting unsafe");
        return uint128(amount);
    }

    function i128(uint256 amount) internal pure returns(int128){
        require (amount < uint128(type(int128).max), "casting unsafe");
        return int128(uint128(amount));
    }
}

interface ILadle {
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external payable;
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function cauldron() external view returns (ICauldron);
    function pools(bytes6 seriesId) external view returns (IPool);
}

interface ICauldron {
    function series(bytes6 seriesId) external view returns (DataTypes.Series memory);
    function balances(bytes12 vault) external view returns (DataTypes.Balances memory);
}

contract YieldSpaceAMO is Owned {
    using SafeCast for uint256;
    using SafeCast for uint128;

    /* =========== CONSTANTS =========== */
    bytes6 public constant FRAX_ILK_ID = 0x313800000000;

    /* =========== DATA TYPES =========== */
    struct Series {
        bytes12 vaultId; /// @notice The AMO's debt & collateral record for this series
        IFYToken fyToken;
        IPool pool;
        uint96 maturity;
    }

    /* =========== STATE VARIABLES =========== */
    
    // Frax
    IFrax private immutable FRAX;
    IFraxAMOMinter private amo_minter;
    address public timelock_address;
    address public custodian_address;

    // Yield Protocol
    ILadle public immutable ladle;
    ICauldron public immutable cauldron;
    address public immutable fraxJoin;
    mapping(bytes6 => Series) public series;
    bytes6[] public seriesIterator;

    // AMO
    uint256 public currentAMOmintedFRAX; /// @notice The amount of FRAX tokens minted by the AMO
    uint256 public currentAMOmintedFyFRAX;

    /* ============= CONSTRUCTOR ============= */
    constructor (
        address _owner_address,
        address _amo_minter_address,
        address _yield_ladle,
        address _yield_frax_join
    ) Owned(_owner_address) {
        FRAX = IFrax(0x853d955aCEf822Db058eb8505911ED77F175b99e);
        amo_minter = IFraxAMOMinter(_amo_minter_address);
        timelock_address = amo_minter.timelock_address();

        ladle = ILadle (_yield_ladle);
        cauldron = ICauldron(ladle.cauldron());
        fraxJoin = _yield_frax_join;

        currentAMOmintedFRAX = 0;
        currentAMOmintedFyFRAX = 0;
    }

    /* ============== MODIFIERS ============== */
    modifier onlyByOwnGov() {
        require (msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByMinter() {
        require (msg.sender == address(amo_minter), "Not minter");
        _;
    }

    /* ================ VIEWS ================ */
    // /// @notice returns current rate on Frax debt
    // function getRate() public view returns (uint256) { //TODO Name better & figure out functionality
    //     return (circulatingAMOMintedFyFrax() - currentRaisedFrax()) / (currentRaisedFrax() * /*timeremaining*/; //TODO pos/neg
    // }

    function showAllocations(bytes6 seriesId) public view returns (uint256[6] memory return_arr) {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        uint256 frax_in_contract = FRAX.balanceOf(address(this));
        uint256 frax_as_collateral = cauldron.balances(_series.vaultId).ink;
        uint256 frax_in_LP = FRAX.balanceOf(address(_series.pool)) * _series.pool.balanceOf(address(this)) / _series.pool.totalSupply();
        uint256 fyFrax_in_contract = _series.fyToken.balanceOf(address(this));
        uint256 fyFrax_in_LP = _series.fyToken.balanceOf(address(_series.pool)) * _series.pool.balanceOf(address(this)) / _series.pool.totalSupply();
        uint256 LP_owned = _series.pool.balanceOf(address(this));
        return [
            frax_in_contract,       // [0] Unallocated Frax
            frax_as_collateral,     // [1] Frax being used as collateral to borrow fyFrax                     
            frax_in_LP,             // [2] The Frax our LP tokens can lay claim to
            fyFrax_in_contract,     // [3] fyFrax sitting in AMO, should be 0
            fyFrax_in_LP,           // [4] fyFrax our LP can claim
            LP_owned                // [5] number of LP tokens
        ];
    }

    /// @notice Return the Frax value of a fyFrax amount, considering a debt repayment if possible.
    function fraxValue(bytes6 seriesId, uint256 fyFraxAmount) public view returns (uint256 fraxAmount) {
        Series storage _series = series[seriesId];
        uint256 debt = cauldron.balances(series[seriesId].vaultId).art;
        if (debt > fyFraxAmount) {
            fraxAmount = fyFraxAmount;
        } else {
            fraxAmount = debt + _series.pool.sellFYTokenPreview((fyFraxAmount - debt).u128());
        }
    }

    /// @notice Return the value of all AMO assets in Frax terms.
    function currentFrax() public view returns (uint256 fraxAmount) {
        // Add value from Frax in the AMO
        fraxAmount = FRAX.balanceOf(address(this));

        // Add up the amount of FRAX in LP positions
        // Add up the value in Frax from all fyFRAX LP positions
        uint256 activeSeries = seriesIterator.length;
        for (uint256 s; s < activeSeries; ++s) {
            bytes6 seriesId = seriesIterator[s];
            Series storage _series = series[seriesId];
            uint256 poolShare = 1e18 * _series.pool.balanceOf(address(this)) / _series.pool.totalSupply();
            
            // Add value from Frax in LP positions
            fraxAmount += FRAX.balanceOf(address(_series.pool)) * poolShare / 1e18;
            
            // Add value from fyFrax in the AMO and LP positions
            uint256 fyFraxAmount = _series.fyToken.balanceOf(address(this));
            fyFraxAmount += _series.fyToken.balanceOf(address(_series.pool)) * poolShare / 1e18;
            fraxAmount += fraxValue(seriesId, fyFraxAmount);
        }
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    function dollarBalances() public view returns (uint256 valueAsFrax, uint256 valueAsCollateral) {
        valueAsFrax = currentFrax();
        valueAsCollateral = valueAsFrax * FRAX.global_collateral_ratio() / 1e6; // This assumes that FRAX.global_collateral_ratio() has 6 decimals
    }
    
    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice register a new series in the AMO
    /// @param seriesId the series being added
    function addSeries(bytes6 seriesId, IFYToken fyToken, IPool pool) public onlyByOwnGov {
        require (ladle.pools(seriesId) == pool, "Mismatched pool");
        require (cauldron.series(seriesId).fyToken == fyToken, "Mismatched fyToken");

        (bytes12 vaultId,) = ladle.build(seriesId, FRAX_ILK_ID, 0);
        series[seriesId] = Series({
            vaultId : vaultId,
            fyToken : fyToken,
            pool : pool,
            maturity: uint96(fyToken.maturity()) // Will work for a while.
        });

        seriesIterator.push(seriesId);
    }

    /// @notice remove a new series in the AMO, to keep gas costs in place
    /// @param seriesId the series being removed
    function removeSeries(bytes6 seriesId) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");
        require (_series.fyToken.balanceOf(address(this)) == 0, "Outstanding fyToken balance");
        require (_series.pool.balanceOf(address(this)) == 0, "Outstanding pool balance");
        delete series[seriesId];

        // Remove the seriesId from the iterator, by replacing for the tail and popping.
        uint256 activeSeries = seriesIterator.length;
        for (uint256 s; s < activeSeries; ++s) {
            if (seriesId == seriesIterator[s]) {
                if (s < activeSeries - 1) {
                    seriesIterator[s] = seriesIterator[activeSeries - 1];
                }
                seriesIterator.pop();
            }
        }
    }

    /// @notice mint fyFrax using FRAX as collateral 1:1 Frax to fyFrax
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series being minted
    /// @param to destination for the fyFrax
    /// @param fraxAmount amount of Frax being used to mint fyFrax at 1:1
    function mintFyFrax(
        bytes6 seriesId,
        address to,
        uint128 fraxAmount
    )
        public onlyByOwnGov
    {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        int128 _fraxAmount = uint256(fraxAmount).i128(); // `using` doesn't work with function overloading
        FRAX.transfer(fraxJoin, fraxAmount);
        ladle.pour(_series.vaultId, to, _fraxAmount, _fraxAmount);
    }

    /// @notice recover Frax from an amount of fyFrax, repaying or redeeming.
    /// Before maturity, if there isn't enough debt to convert all the fyFrax into Frax, the surplus
    /// will be stored in the AMO. Calling this function after maturity will redeem the surplus.
    /// @dev The fyFrax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series being burned
    /// @param to destination for the frax recovered
    /// @param fyFraxAmount amount of fyFrax being burned
    /// @return fraxAmount amount of Frax recovered
    /// @return fyFraxAmount amount of fyFrax stored in the AMO
    function burnFyFrax(
        bytes6 seriesId,
        address to,
        uint128 fyFraxAmount,
    )
        public onlyByOwnGov
        returns (uint256 fraxAmount, fyFraxAmount)
    { 
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        if (_series.maturity < block.timestamp) { // At maturity, forget about debt and redeem at 1:1
            _series.fyToken.transfer(address(_series.fyToken), fyFraxAmount);
            fraxAmount = _series.fyToken.redeem(to, fyFraxAmount);
        } else { // Before maturity, repay as much debt as possible, and keep any surplus fyFrax
            uint256 debt = cauldron.balances(series[seriesId].vaultId).art;
            (fraxAmount, fyFraxAmount) = debt > fyFraxAmount ? (fyFraxAmount, 0) : (debt, fyFraxAmount - debt)); // After this, `fyFraxAmount` has the surplus.

            _series.fyToken.transfer(address(_series.fyToken), fraxAmount);
            ladle.pour(_series.vaultId, to, -(fraxAmount.i128()), -(fraxAmount.i128()));
        }
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates 
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series we are increasing the rates for
    /// @param to destination for the frax recovered, usually the AMO
    /// @param fraxAmount amount of Frax being converted to fyFrax and sold
    /// @param minFraxReceived minimum amount of Frax to receive in the sale
    /// @return fraxReceived amount of Frax received in the sale
    function increaseRates(
        bytes6 seriesId,
        address to,
        uint128 fraxAmount,
        uint128 minFraxReceived
    )
        public onlyByOwnGov
        returns (uint256 fraxReceived)
    {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Mint fyFRAX into the pool, and sell it.
        mintFyFrax(seriesId, address(_series.pool), fraxAmount);
        fraxReceived = _series.pool.sellFYToken(to, minFraxReceived);
        emit RatesIncreased(fraxAmount, fraxReceived);
    }

    /// @notice buy fyFrax from the AMO and burn it to push down rates
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series we are decreasing the rates for
    /// @param to destination for the frax recovered, usually the AMO
    /// @param fraxAmount amount of Frax being sold for fyFrax
    /// @param minFyFraxReceived minimum amount of fyFrax in the sale
    /// @return fraxReceived amount of Frax received after selling and burning
    /// @return fyFraxStored amount of fyFrax stored in the AMO, if any
    function decreaseRates(
        bytes6 seriesId,
        address to,
        uint128 fraxAmount,
        uint128 minFyFraxReceived
    )
        public onlyByOwnGov
        returns (uint256 fraxReceived, uint256 fyFraxStored)
    {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(address(_series.pool), fraxAmount);
        uint256 fyFraxReceived = _series.pool.sellBase(address(_series.fyToken), minFyFraxReceived);
        (fraxReceived, fyFraxStored) = burnFyFrax(seriesId, to, fyFraxReceived.u128());
        emit RatesDecreased(fraxAmount, fraxReceived);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    /// @dev The Frax to work with needs to be in the AMO already.
    /// @param seriesId fyFrax series we are adding liquidity for
    /// @param to destination for the pool tokens minted, usually the AMO
    /// @param remainder destination for any unused Frax, usually the AMO
    /// @param fraxAmount amount of Frax being provided as liquidity
    /// @param fyFraxAmount amount of fyFrax being provided as liquidity
    /// @param minRatio minimum Frax/fyFrax ratio accepted in the pool
    /// @param maxRatio maximum Frax/fyFrax ratio accepted in the pool
    /// @return fraxUsed amount of Frax used for minting, it could be less than `fraxAmount`
    /// @return poolMinted amount of pool tokens minted
    function addLiquidityToAMM(
        bytes6 seriesId,
        address to,
        address remainder,
        uint128 fraxAmount,
        uint128 fyFraxAmount,
        uint256 minRatio,
        uint256 maxRatio
    )
        public onlyByOwnGov
        returns (uint256 fraxUsed, uint256 poolMinted)
    {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        mintFyFrax(seriesId, address(_series.pool), fyFraxAmount);
        FRAX.transfer(address(_series.pool), fraxAmount);
        (fraxUsed,, poolMinted) = _series.pool.mint(to, remainder, minRatio, maxRatio); //Second param receives remainder
        emit LiquidityAdded(fraxUsed, poolMinted);
    }

    /// @notice remove liquidity and burn fyTokens
    /// @dev The pool tokens to work with need to be in the AMO already.
    /// @param seriesId fyFrax series we are adding liquidity for
    /// @param to destination for the Frax obtained, usually the AMO
    /// @param poolAmount amount of pool tokens being removed as liquidity
    /// @param minRatio minimum Frax/fyFrax ratio accepted in the pool
    /// @param maxRatio maximum Frax/fyFrax ratio accepted in the pool
    /// @return fraxReceived amount of Frax received after removing liquidity and burning
    /// @return fyFraxStored amount of fyFrax stored in the AMO, if any
    function removeLiquidityFromAMM(
        bytes6 seriesId,
        address to,
        uint256 poolAmount,
        uint256 minRatio,
        uint256 maxRatio
    ) public onlyByOwnGov returns (uint256 fraxReceived, uint256 fyFraxStored) {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the fyFRAX contract.
        //Instruct the Ladle to repay as much debt as fyFRAX from the burn, and withdraw the same amount of collateral.
        _series.pool.transfer(address(_series.pool), poolAmount);
        (,, uint256 fyFraxAmount) = _series.pool.burn(to, address(_series.fyToken), minRatio, maxRatio);
        (fraxReceived, fyFraxStored) = burnFyFrax(seriesId, to, fyFraxAmount.u128());
        emit LiquidityRemoved(fraxReceived, poolAmount);
    }

    /* === RESTRICTED GOVERNANCE FUNCTIONS === */
    function setAMOMinter(IFraxAMOMinter _amo_minter) external onlyByOwnGov {
        amo_minter = _amo_minter;

        // Get the timelock addresses from the minter
        timelock_address = _amo_minter.timelock_address();

        // Make sure the new addresses are not address(0)
        require (timelock_address != address(0), "Invalid timelock");
        emit AMOMinterSet(address(_amo_minter));
    }

    /// @notice generic proxy
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = to.call{value:value}(data);
        return (success, result);
    }

    /* ================ EVENTS =============== */
    //TODO What other events do we want?
    event LiquidityAdded(uint fraxUsed, uint poolMinted);
    event LiquidityRemoved(uint fraxReceived, uint poolBurned);
    event RatesIncreased(uint fraxUsed, uint fraxReceived);
    event RatesDecreased(uint fraxUsed, uint fraxReceived);
    event AMOMinterSet(address amo_minter_address);

}