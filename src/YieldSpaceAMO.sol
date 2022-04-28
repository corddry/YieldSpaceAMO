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
    /* =========== CONSTANTS =========== */
    bytes6 public constant FRAX_ILK_ID = 0x3138;

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

     /* ============== UTILITY =============== */
    function safeToInt(uint256 amount) private pure returns(int128){
        require (amount < 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, "integer casting unsafe"); //max uint in 127 bits
        return int128(uint128(amount));
    }

    /* ================ VIEWS ================ */
    // /// @notice returns current rate on Frax debt
    // function getRate() public view returns (uint256) { //TODO Name better & figure out functionality
    //     return (circulatingAMOMintedFyFrax() - currentRaisedFrax()) / (currentRaisedFrax() * /*timeremaining*/; //TODO pos/neg
    // }

    function showAllocations(bytes6 seriesId) public view returns (uint256[5] memory return_arr) {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        uint256 frax_in_contract = FRAX.balanceOf(address(this));
        uint256 frax_as_collateral = uint256(cauldron.balances(_series.vaultId).ink);
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

    function currFraxInAMOLP(bytes6 seriesId) public view returns (uint256) {
        uint256[6] memory arr = showAllocations(seriesId);
        return arr[2];
        // return FRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }
    
    function currFyFraxInAMOLP(bytes6 seriesId) public view returns (uint256) {
        uint256[6] memory arr = showAllocations(seriesId);
        return arr[4];
        // return fyFRAX.balanceOf(address(pool)) * pool.balanceOf(address(this)) / pool.totalSupply();
    }

    /// @return raisedFrax The Frax fundraised by the AMO
    /// @return isNegative True if currFrax should be flipped in sign, ie the LP has less Frax than it began with
    function currentRaisedFrax(bytes6 seriesId) public view returns (uint256 raisedFrax, bool isNegative) {
        uint256 fraxInLP = currFraxInAMOLP(seriesId);
        if (fraxInLP >= fraxLiquidityAdded) { //Frax has entered the AMO's LP
            return (fraxInLP - fraxLiquidityAdded, false);
        } else { //Frax has left the AMO's LP
            return (fraxLiquidityAdded - fraxInLP, true);
        }
    }

    /// @notice returns the current amount of FRAX that the protocol must pay out on maturity of circulating fyFRAX in the open market
    /// @notice signed return value
    function circulatingAMOMintedFyFrax(bytes6 seriesId) public view returns (uint256 circulatingFyFrax, bool isNegative) {
        uint256 fyFraxInLP = currFyFraxInAMOLP(seriesId);
        if (fyFraxLiquidityAdded >= fyFraxInLP) { //AMO minted fyFrax has left the LP
            return (fyFraxLiquidityAdded - fyFraxInLP, false);
        } else { //non-AMO minted fyFrax has entered the LP
            return (fyFraxInLP - fyFraxLiquidityAdded, true);
        }
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    function dollarBalances() public view returns (uint256 frax_val_e18, uint256 collat_val_e18) {
        uint precision = 1000000;
        (uint256 circFyFrax, bool circFyFraxisNegative) = circulatingAMOMintedFyFrax();
        (uint256 raisedFrax, bool raisedFraxisNegative) = currentRaisedFrax();
        uint256 sum = currentAMOmintedFRAX * (FRAX.global_collateral_ratio() / precision);
        sum = raisedFraxisNegative ? sum - raisedFrax : sum + raisedFrax; //TODO ensure nonnegative

        uint fyFraxMarketPrice = precision * pool.getFYTokenBalance() / pool.getBaseBalance(); //TODO check this formula
        sum = circFyFraxisNegative ? sum + (circFyFrax * fyFraxMarketPrice / precision) : sum - (circFyFrax * fyFraxMarketPrice / precision);
        return (sum, sum * fyFraxMarketPrice / precision);
        //Normal conditions: return currentAMOmintedFRAX  + currentRaisedFrax() - circFyFrax * mkt price; 
    }
    
    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice register a new series in the AMO
    function addSeries(bytes6 seriesId, IFYToken fyToken, IPool pool) public onlyByOwnGov {
        require (ladle.pools(seriesId) == address(pool), "Mismatched pool");
        require (cauldron.series(seriesId).fyToken == address(fyToken), "Mismatched fyToken");

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
    function mintFyFrax(bytes6 seriesId, uint128 _amount) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX to the FRAX Join, add it as collateral, and borrow.
        int128 intAmount = safeToInt(_amount);
        FRAX.transfer(fraxJoin, _amount);
        ladle.pour(_series.vaultId, address(this), intAmount, intAmount);
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax(bytes6 seriesId) public onlyByOwnGov { 
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer fyFRAX to the fyFRAX contract, repay debt, and withdraw FRAX collateral.
        uint256 fyFraxAmount = _series.fyToken.balanceOf(address(this));
        _series.fyToken.transfer(address(_series.fyToken), fyFraxAmount);
        ladle.pour(_series.vaultId, address(this), -safeToInt(fyFraxAmount), -safeToInt(fyFraxAmount));
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates 
    function increaseRates(bytes6 seriesId, uint128 _fraxAmount, uint128 _minFraxReceived) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Mint fyFRAX into the pool, and sell it.
        uint256 fyFraxAmount = _fraxAmount;
        FRAX.transfer(fraxJoin, _fraxAmount);
        ladle.pour(_series.vaultId, address(_series.pool), safeToInt(_fraxAmount), safeToInt(fyFraxAmount));
        _series.pool.sellFYToken(address(this), _minFraxReceived);
        emit ratesIncreased(_fraxAmount, _minFraxReceived);
    }

    /// @notice buy fyFrax from the AMO and burn it to push down rates
    function decreaseRates(bytes6 seriesId, uint128 _fraxAmount, uint128 _minFyFraxReceived) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool, sell it for fyFRAX into the fyFRAX contract, repay debt and withdraw FRAX collateral.
        FRAX.transfer(address(_series.pool), _fraxAmount);
        uint256 fyFraxReceived = _series.pool.sellBase(address(_series.fyToken), _minFyFraxReceived);
        uint256 fraxCollat = fyFraxReceived;
        ladle.pour(_series.vaultId, address(this), -safeToInt(fraxCollat), -safeToInt(fyFraxReceived));
        emit ratesDecreased(_fraxAmount, _minFyFraxReceived);
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(bytes6 seriesId, uint128 _fraxAmount, uint128 _fyFraxAmount, uint256 _minRatio, uint256 _maxRatio) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer FRAX into the pool. Transfer FRAX into the FRAX Join. Borrow fyFRAX into the pool. Add liquidity.
        FRAX.transfer(fraxJoin, _fyFraxAmount);
        FRAX.transfer(address(_series.pool), _fraxAmount);
        ladle.pour(_series.vaultId, address(_series.pool), safeToInt(_fyFraxAmount), safeToInt(_fyFraxAmount));
        _series.pool.mint(address(this), address(this), _minRatio, _maxRatio); //Second param receives remainder
        emit liquidityAdded(_fraxAmount, _fyFraxAmount);
    }

    /// @notice remove liquidity and burn fyTokens
    function removeLiquidityFromAMM(bytes6 seriesId, uint256 _poolAmount, uint256 _minRatio, uint256 _maxRatio) public onlyByOwnGov {
        Series storage _series = series[seriesId];
        require (_series.vaultId != bytes12(0), "Series not found");

        //Transfer pool tokens into the pool. Burn pool tokens, with the fyFRAX going into the fyFRAX contract.
        //Instruct the Ladle to repay as much debt as fyFRAX from the burn, and withdraw the same amount of collateral.
        _series.pool.transfer(address(_series.pool), _poolAmount);
        (,, uint256 fyFraxAmount) = _series.pool.burn(address(this), _series.fyToken, _minRatio, _maxRatio);
        ladle.pour(_series.vaultId, address(this), -safeToInt(fyFraxAmount), -safeToInt(fyFraxAmount));
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
