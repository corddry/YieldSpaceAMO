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
    uint256 public fraxLiquidityAdded; /// @notice The amount FRAX added to LP
    uint256 public fyFraxLiquidityAdded;

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
        fraxLiquidityAdded = 0;
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

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    function dollarBalances() public view returns (uint256 valueAsFrax, uint256 valueAsCollateral) {
        // TODO: Not sure, but is this supposed to add up the amount of FRAX from every destination?
        // If so, shouldn't we get the Frax held by this contract instead?
        uint256 precision = 1e6;
        uint256 fraxValue = currentAMOmintedFRAX * FRAX.global_collateral_ratio() / precision;
        uint256 fyFraxValue;

        // Add up the amount of FRAX in LP positions
        // Add up the value in Frax from all fyFRAX LP positions
        uint256 activeSeries = seriesIterator.length;
        for (uint256 s; s < activeSeries; ++s) {
            bytes6 seriesId = seriesIterator[s];
            Series storage _series = series[seriesId];
            uint256 share = 1e18 * _series.pool.balanceOf(address(this)) / _series.pool.totalSupply();
            fraxValue += FRAX.balanceOf(address(_series.pool)) * share / 1e18;
            uint256 fyFraxAmount = _series.fyToken.balanceOf(address(_series.pool)) * share / 1e18;
            fyFraxValue += _series.pool.sellFYTokenPreview(fyFraxAmount.u128());
        }

        valueAsFrax = fraxValue + fyFraxValue - fraxLiquidityAdded - fyFraxLiquidityAdded;
        valueAsCollateral = 0; // TODO: What is this, exactly?

        //Normal conditions: return currentAMOmintedFRAX  + currentRaisedFrax() - circFyFrax * mkt price; 
    }
    
    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice register a new series in the AMO
    function addSeries(bytes6 seriesId, IFYToken fyToken, IPool pool) public onlyByOwnGov {
        require (ladle.pools(seriesId) == pool, "Mismatched pool");
        require (cauldron.series(seriesId).fyToken == fyToken, "Mismatched fyToken");

        (bytes12 vaultId,) = ladle.build(seriesId, FRAX_ILK_ID, 0);
        series[seriesId] = Series({
            vaultId : vaultId,
            fyToken : fyToken,
            pool : pool
        });

        seriesIterator.push(seriesId);
    }

    /// @notice remove a new series in the AMO, to keep gas costs in place
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
    function mintFyFrax(bytes6 seriesId, uint128 amount) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        int128 _amount = uint256(amount).i128(); // `using` doesn't work with function overloading
        FRAX.transfer(fraxJoin, amount);
        ladle.pour(_series.vaultId, address(this), _amount, _amount);
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax(bytes6 seriesId) public onlyByOwnGov { 
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer fyFRAX to the fyFRAX contract, repay debt, and withdraw FRAX collateral.
        uint256 fyFraxAmount = _series.fyToken.balanceOf(address(this));
        int128 _fyFraxAmount = fyFraxAmount.i128();
        _series.fyToken.transfer(address(_series.fyToken), fyFraxAmount);
        ladle.pour(_series.vaultId, address(this), -_fyFraxAmount, -_fyFraxAmount);
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates 
    function increaseRates(bytes6 seriesId, uint128 fraxAmount, uint128 minFraxReceived) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Mint fyFRAX into the pool, and sell it.
        uint256 fyFraxAmount = fraxAmount;
        FRAX.transfer(fraxJoin, fraxAmount);
        ladle.pour(_series.vaultId, address(_series.pool), fraxAmount.i128(), fyFraxAmount.i128());
        _series.pool.sellFYToken(address(this), minFraxReceived);
        emit ratesIncreased(fraxAmount, minFraxReceived);
    }

    /// @notice buy fyFrax from the AMO and burn it to push down rates
    function decreaseRates(bytes6 seriesId, uint128 fraxAmount, uint128 minFyFraxReceived) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(address(_series.pool), fraxAmount);
        uint256 fyFraxReceived = _series.pool.sellBase(address(_series.fyToken), minFyFraxReceived);
        uint256 fraxCollat = fyFraxReceived;
        ladle.pour(_series.vaultId, address(this), -(fraxCollat.i128()), -(fyFraxReceived.i128()));
        emit ratesDecreased(fraxAmount, minFyFraxReceived);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(bytes6 seriesId, uint128 fraxAmount, uint128 fyFraxAmount, uint256 minRatio, uint256 maxRatio) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        FRAX.transfer(fraxJoin, fyFraxAmount);
        FRAX.transfer(address(_series.pool), fraxAmount);
        ladle.pour(_series.vaultId, address(_series.pool), fyFraxAmount.i128(), fyFraxAmount.i128());
        _series.pool.mint(address(this), address(this), minRatio, maxRatio); //Second param receives remainder
        emit liquidityAdded(fraxAmount, fyFraxAmount);
    }

    /// @notice remove liquidity and burn fyTokens
    function removeLiquidityFromAMM(bytes6 seriesId, uint256 _poolAmount, uint256 minRatio, uint256 maxRatio) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the fyFRAX contract.
        //Instruct the Ladle to repay as much debt as fyFRAX from the burn, and withdraw the same amount of collateral.
        _series.pool.transfer(address(_series.pool), _poolAmount);
        (,, uint256 fyFraxAmount) = _series.pool.burn(address(this), _series.fyToken, minRatio, maxRatio);
        ladle.pour(_series.vaultId, address(this), -(fyFraxAmount.i128()), -(fyFraxAmount).i128());
        emit liquidityRemoved(_poolAmount);
    }

    /* === RESTRICTED GOVERNANCE FUNCTIONS === */
    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IFraxAMOMinter(_amo_minter_address);

        // Get the timelock addresses from the minter
        timelock_address = amo_minter.timelock_address();

        // Make sure the new addresses are not address(0)
        require (timelock_address != address(0), "Invalid timelock");
        emit AMOMinterSet(_amo_minter_address);
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
    //TODO What other events do we want?
    event liquidityAdded(uint fraxAmount, uint fyFraxAmount);
    event liquidityRemoved(uint poolAmount);
    event ratesIncreased(uint fraxAmount, uint minFraxReceived);
    event ratesDecreased(uint fraxAmount, uint minFyFraxReceived);
    event AMOMinterSet(address amo_minter_address);

}
