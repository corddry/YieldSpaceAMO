// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import {FraxMock} from "./mocks/FraxMock.sol";
import {IFrax} from "../src/interfaces/IFrax.sol";
import {FYTokenMock} from "./mocks/FYTokenMock.sol";
import {YieldSpaceAMO} from "src/YieldSpaceAMO.sol";
import {Pool} from "yieldspace-v2/contracts/Pool.sol";
import {IPool} from "yieldspace-interfaces/IPool.sol";
import {IFYToken} from "vault-interfaces/IFYToken.sol";
import {FraxVaultMock} from "./mocks/FraxVaultMock.sol";
import {AMOMinterMock} from "./mocks/AMOMinterMock.sol";
import {DataTypes} from "vault-interfaces/DataTypes.sol";
import {YieldMath} from "yieldspace-v2/contracts/YieldMath.sol";
import {IERC20} from "yield-utils-v2/contracts/token/IERC20.sol";
import {SafeERC20Namer} from "yield-utils-v2/contracts/token/SafeERC20Namer.sol";

// TESTING STATE TREE:
// X Zero State
// X addSeries -> WithSeries
//   X remove series
//   X addAdditionalSeries => WithTwoSeries
//     X mintFyFrax
//     X burnFyFrax
//     X burnFyFrax up to debt level
//     X burnFyFrax with mature fyFrax
//     X add liquidity with borrowing some fyfrax
//     X add liquidity with some fyFrax already there
//     X add liquidity with some frax already there
//     X add liquidity with both already there
//     X addLiquidity to a second pool
//     X addLiquidity -> WithLiquidityInYieldSpace
//       X increaseRates - with preExistingFytokne
//       X increaseRates - WithIncreasedRates
//         X decreaseRates
//         X removeLiquidity
//         X warp to maturity and check views

abstract contract ZeroState is Test {
    FraxVaultMock public yield;
    FraxMock public base;
    YieldSpaceAMO public amo;
    AMOMinterMock public amoMinter;
    address public fraxJoin;

    bytes6 public constant series0Id = 0x313830370000;
    bytes6 public constant series1Id = 0x313830380000;
    uint32 public maturity0; //  80 days from today;
    uint32 public maturity1; //  170 days from today;

    int128 public constant ts = 14613551152;
    int128 public constant g1 = 13835058055282163712;
    int128 public constant g2 = 24595658764946068821;

    address public constant owner = address(0xB0B);

    event LiquidityAdded(uint256 fraxUsed, uint256 poolMinted);
    event LiquidityRemoved(uint256 fraxReceived, uint256 poolBurned);
    event RatesIncreased(uint256 fraxUsed, uint256 fraxReceived);
    event RatesDecreased(uint256 fraxUsed, uint256 fraxReceived);
    event AMOMinterSet(address amoMinterAddress);

    function setUp() public virtual {
        uint32 day = 24 * 60 * 60;
        maturity0 = uint32(block.timestamp) + 80 * day;
        maturity0 = uint32(block.timestamp) + 170 * day;
        vm.label(owner, "Bob (owner)");
        yield = new FraxVaultMock();
        fraxJoin = address(yield); // Using the FraxVaultMock address as the join address
        base = yield.base();
        amoMinter = new AMOMinterMock();
        vm.prank(owner);
        amo = new YieldSpaceAMO(owner, address(amoMinter), address(yield), fraxJoin, address(base));
    }

    struct CheckViewsParams {
        bytes6 seriesId_showAllocations;
        uint256[6] expected_showAllocations;
        // expected_showAllocations based on showAllocations return value:
        // [0] fraxInContract: unallocated fees
        // [1] fraxAsCollateral: Frax used as collateral
        // [2] fraxInLP: The Frax our LP tokens can lay claim to
        // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
        // [4] fyFraxInLP: fyFrax our LP can claim
        // [5] LPOwned: number of LP tokens
        bytes6 seriesId_fraxValue;
        uint256 fyFraxAmount_fraxValue;
        uint256 expectedAmount_fraxValue;
        uint256 expectedFraxAmount_currentFrax;
        uint256 expectedValueAsFrax_dollarBalances;
    }

    // This is used to quickly check all view fns in the AMO
    function checkViews(CheckViewsParams memory params) public {
        // check showAllocations()
        uint256[6] memory allocations = amo.showAllocations(params.seriesId_showAllocations);
        require(allocations[0] == params.expected_showAllocations[0]); // [0] fraxInContract: unallocated fees
        require(allocations[1] == params.expected_showAllocations[1]); // [1] fraxAsCollateral: Frax used as collateral
        require(allocations[2] == params.expected_showAllocations[2]); // [2] fraxInLP: The Frax our LP tokens can lay claim to
        require(allocations[3] == params.expected_showAllocations[3]); // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
        require(allocations[4] == params.expected_showAllocations[4]); // [4] fyFraxInLP: fyFrax our LP can claim
        require(allocations[5] == params.expected_showAllocations[5]); // [5] LPOwned: number of LP tokens

        // check fraxValue()
        uint256 actualFraxValue = amo.fraxValue(params.seriesId_fraxValue, params.fyFraxAmount_fraxValue);
        require(actualFraxValue == params.expectedAmount_fraxValue);

        // check currentFrax()
        require(amo.currentFrax() == params.expectedFraxAmount_currentFrax);

        // check dollarBalances()
        (uint256 valueAsFrax, uint256 valueAsCollateral) = amo.dollarBalances();
        require(valueAsFrax == params.expectedValueAsFrax_dollarBalances);
        require(
            valueAsCollateral ==
                (params.expectedValueAsFrax_dollarBalances *
                    base.global_collateral_ratio()) /
                    1e6
        );
    }

    // This is used to debug
    function displayViewFns() public {
        // check showAllocations()
        uint256[6] memory allocations = amo.showAllocations(series0Id);

        console.log("showAllocations");
        for (uint256 i; i < 6; i++) {
            console.log(i, allocations[i]);
        }

        console.log("fraxValue", amo.fraxValue(series0Id, 1_000_000));

        console.log("currentFrax", amo.currentFrax());

        (uint256 valueAsFrax, uint256 valueAsCollateral) = amo.dollarBalances();
        console.log("dollarBalances - valueAsFrax", valueAsFrax);
        console.log("dollarBalances - valueAsCollateral", valueAsCollateral);
    }

    function yieldAddSeriesAndPool(bytes6 seriesId, uint32 maturity)
        public
        returns (FYTokenMock newFyToken, Pool newPool)
    {
        yield.addSeries(seriesId, maturity);
        (IFYToken fyToken_, , ) = yield.series(seriesId);
        newFyToken = FYTokenMock(address(fyToken_));
        newPool = new Pool(IERC20(address(base)), fyToken_, ts, g1, g2);
        yield.addPool(seriesId, newPool);
    }
}

contract YieldSpaceAMO_ZeroState is ZeroState {
    /* addSeries()
     ******************************************************************************************************************/

    function testReverts_addSeries_MismatchedPool() public {
        console.log("addSeries() reverts on mismatched pool");
        yieldAddSeriesAndPool(series0Id, maturity0); // add series on Yield side
        vm.expectRevert("Mismatched pool");
        vm.prank(owner);
        amo.addSeries(series0Id, IFYToken(address(0xb0ffed1)), IPool(address(0xb0ffed2)));
    }

    function testReverts_addSeries_MismatchedFyToken() public {
        console.log("addSeries() reverts on mismatched fyToken");
        (, Pool newPool) = yieldAddSeriesAndPool(series0Id, maturity0); // add series on Yield side

        vm.expectRevert("Mismatched fyToken");
        vm.prank(owner);
        amo.addSeries(series0Id, IFYToken(address(0x1)), IPool(address(newPool)));
    }

    function testUnit_addSeries() public {
        console.log("addSeries() can add a series");
        require(amo.seriesIterator().length == 0);
        (FYTokenMock newFyToken, Pool newPool) = yieldAddSeriesAndPool(series0Id, maturity0); // add series on Yield side

        vm.prank(owner);
        amo.addSeries(series0Id, IFYToken(address(newFyToken)), newPool);
        require(amo.seriesIterator().length == 1);
        (bytes12 vaultIdFound, IFYToken fyTokenFound, IPool poolFound, uint96 maturityFound) = amo.series(series0Id);
        require(vaultIdFound == bytes12(yield.lastVaultId() - 1)); // "lastVaultId" is really "nextVaultId" so we subtract 1
        require(address(fyTokenFound) == address(newFyToken));
        require(address(poolFound) == address(newPool));
        require(maturityFound == maturity0);

        // check view fns -- expect all zeros
        uint256[6] memory expecteds;
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expecteds, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                0, // fyFraxAmount_fraxValue
                0, // expectedAmount_fraxValue
                0, // expectedFraxAmount_currentFrax
                0 // expectedValueAsFrax_dollarBalances
            )
        );
    }

    // NOTE: revert on Series not found tested above in: testReverts_addLiquidityToAMM_SeriesNotFound()

    function testReverts_mintFyFrax_NotOwner() public {
        console.log("addLiquidity() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint128 fyFraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);
    }

    function testReverts_burnFyFrax_NotOwner() public {
        console.log("addLiquidity() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint128 fyFraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);
    }

    function testReverts_increaseRates_NotOwner() public {
        console.log("addLiquidity() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint128 fyFraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);
    }

    function testReverts_decreaseRates_NotOwner() public {
        console.log("addLiquidity() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint128 fyFraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);
    }

    function testReverts_addLiquidityTo_NotOwner() public {
        console.log("addLiquidity() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint128 fyFraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);
    }

    function testReverts_removeLiquidityTo_NotOwner() public {
        console.log("removeLiquidityFromAMM() reverts if not owner or timelock");

        uint128 fraxAmount = 1_000_000 * 1e18;
        vm.expectRevert("Not owner or timelock");
        (uint256 fraxUsed, uint256 poolMinted) = amo.removeLiquidityFromAMM(series0Id, fraxAmount, 0, 1);
    }

    function testReverts_removeSeries_SeriesNotFound() public {
        console.log("removeSeries() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.removeSeries(series1Id, 0);
    }

    function testReverts_mintFyFrax_SeriesNotFound() public {
        console.log("mintFyFrax() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.mintFyFrax(series1Id, 10000000);
    }

    function testReverts_burnFyFrax_SeriesNotFound() public {
        console.log("burnFyFrax() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.burnFyFrax(series1Id, 10000000);
    }

    function testReverts_increaseRates_SeriesNotFound() public {
        console.log("increaseRates() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.increaseRates(series0Id, 1e18, 1e18);
    }

    function testReverts_decreaseRates_SeriesNotFound() public {
        console.log("decreaseRates() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.decreaseRates(series1Id, 1e18, 1e18);
    }

    function testReverts_addLiquidityToAMM_SeriesNotFound() public {
        console.log("addLiquidityToAMM() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.addLiquidityToAMM(series1Id, 1, 1, 0, 1);
    }

    function testReverts_removeLiquidityFromAMM_SeriesNotFound() public {
        console.log("removeLiquidityFromAMM() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.removeLiquidityFromAMM(series1Id, 1, 0, 1);
    }
}


abstract contract WithSeriesAdded is ZeroState {
    FYTokenMock public fyToken0; // first token added
    Pool public pool0; // first pool added

    function setUp() public virtual override {
        super.setUp();
        (fyToken0, pool0) = yieldAddSeriesAndPool(series0Id, maturity0);
        vm.prank(owner);
        amo.addSeries(series0Id, IFYToken(address(fyToken0)), pool0);
    }
}

contract YieldSpaceAMO_WithSeriesAdded is WithSeriesAdded {
    // NOTE: The test for reverting on "Index mismatch" is found below in WithTwoSeriesAdded tests.

    function testReverts_removeSeries_OutstandingFyTokenBal() public {
        console.log("removeSeries() reverts if amo has fyToken balance");
        (, IFYToken fyToken_, , ) = amo.series(series0Id);
        fyToken_.mint(address(amo), 20 * 1e18);
        vm.expectRevert("Outstanding fyToken balance");
        vm.prank(owner);
        amo.removeSeries(series0Id, 0);
    }

    function testReverts_removeSeries_OutstandingPoolBal() public {
        console.log("removeSeries() reverts if amo has pool LP balance");

        (, , IPool pool_, ) = amo.series(series0Id);

        // give base to pool
        base.mint(address(pool_), 10 * 1e18);
        // then mint lp tokens to AMO
        pool_.mint(address(amo), address(amo), 0, type(uint256).max);

        vm.expectRevert("Outstanding pool balance");
        vm.prank(owner);
        amo.removeSeries(series0Id, 0);
    }

    function testUnit_removeSeries() public {
        console.log("removeSeries() can removeSeries");
        require(amo.seriesIterator().length == 1);
        vm.prank(owner);
        amo.removeSeries(series0Id, 0);
        require(amo.seriesIterator().length == 0);
    }

    /* addSeries()
     ******************************************************************************************************************/

    function testUnit_addSeries_addsAdditional() public {
        console.log("addSeries() can add an additional series");
        require(amo.seriesIterator().length == 1);
        (FYTokenMock newFyToken, Pool newPool) = yieldAddSeriesAndPool(series1Id, maturity1); // add series on Yield side

        vm.prank(owner);
        amo.addSeries(series1Id, IFYToken(address(newFyToken)), newPool);
        require(amo.seriesIterator().length == 2);
        (bytes12 vaultIdFound, IFYToken fyTokenFound, IPool poolFound, uint96 maturityFound) = amo.series(series1Id);
        require(vaultIdFound == bytes12(yield.lastVaultId() - 1)); // "lastVaultId" is really "nextVaultId" so we subtract 1
        require(address(fyTokenFound) == address(newFyToken));
        require(address(poolFound) == address(newPool));
        require(maturityFound == maturity1);
    }
}


abstract contract WithTwoSeriesAdded is WithSeriesAdded {
    FYTokenMock public fyToken1; // second token added
    Pool public pool1; // second pool added

    function setUp() public virtual override {
        super.setUp();
        (fyToken1, pool1) = yieldAddSeriesAndPool(series1Id, maturity1); // add series on Yield side
        vm.prank(owner);
        amo.addSeries(series1Id, IFYToken(address(fyToken1)), pool1);
    }
}

contract YieldSpaceAMO_WithTwoSeriesAdded is WithTwoSeriesAdded {
    /* removeSeries()
     ******************************************************************************************************************/
    function testReverts_removeSeries_IndexMismatch() public {
        console.log("removeSeries() reverts if series found in mapping does not match iterator");

        // add another series first to more realistically cause an index mismatch
        (FYTokenMock newFyToken, Pool newPool) = yieldAddSeriesAndPool(series1Id, maturity1); // add series on Yield side
        vm.prank(owner);
        amo.addSeries(series1Id, IFYToken(address(newFyToken)), newPool);
        (bytes12 vaultIdFound, IFYToken fyTokenFound, IPool poolFound, uint96 maturityFound) = amo.series(series1Id);

        vm.expectRevert("Index mismatch");
        vm.prank(owner);
        amo.removeSeries(series1Id, 0);
    }

    /* mintFYFrax()
     ******************************************************************************************************************/

    function testUnit_mintFyFrax() public {
        console.log("mintFyFrax() can mint without liquidity in pool");
        require(fyToken0.balanceOf(address(amo)) == 0);
        uint128 amount = 100 * 1e18;
        base.mint(address(amo), amount);

        vm.prank(owner);
        amo.mintFyFrax(series0Id, amount);
        require(fyToken0.balanceOf(address(amo)) == amount);
        (bytes12 vaultId, , , ) = amo.series(series0Id);
        (uint128 art, uint128 ink) = yield.balances(vaultId);
        require(art == amount);
        require(ink == amount);

        // check view fns
        uint256[6] memory expectedAllocations = [
            uint256(0), // [0] fraxInContract: unallocated fees
            ink, // [1] fraxAsCollateral: Frax used as collateral
            0, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            amount, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            0 // [5] LPOwned: number of LP tokens
        ];

        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                amount + 1e18, // fyFraxAmount_fraxValue
                amount, // expectedAmount_fraxValue
                amount, // expectedFraxAmount_currentFrax
                amount // expectedValueAsFrax_dollarBalances
            )
        );

        // NOTE: by adding 1e18 to the debt amount for fyFraxAmount_fraxValue, we are able to test the
        // final error condition in the fraxValue fn:
        // >  If for some reason the fyFrax can't be sold, we value it at zero"
        // It cannot be sold because there is not yet any liquidity in the pool.
    }

    /* addLiquidity()
     ******************************************************************************************************************/

    function testUnit_addLiquidityToAMM_FraxOnly() public {
        console.log("addLiquidity() can add first time liquidity to AMM with frax only");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint256 expectedLpTokens = 1_000_000 * 1e18;
        base.mint(address(amo), fraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, 0, 0, 1);

        require(pool0.balanceOf(address(amo)) == expectedLpTokens);
        require(base.balanceOf(address(pool0)) == fraxAmount);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool0.getCache();
        require(baseCached == fraxAmount);
        require(fyTokenCached == expectedLpTokens); // "virtual fyToken balance"

        // check view fns
        uint256[6] memory expectedAllocations = [
            uint256(0), // [0] fraxInContract: unallocated fees
            0, // [1] fraxAsCollateral: Frax used as collateral
            fraxAmount, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            expectedLpTokens // [5] LPOwned: number of LP tokens
        ];

        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                0, // fyFraxAmount_fraxValue
                0, // expectedAmount_fraxValue
                fraxAmount, // expectedFraxAmount_currentFrax
                fraxAmount // expectedValueAsFrax_dollarBalances
            )
        );
    }
}

abstract contract WithDebtAndFyFraxInAMO is WithTwoSeriesAdded {
    function setUp() public virtual override {
        super.setUp();
        uint128 fraxAmount = 1_000_000 * 1e18;
        base.mint(address(amo), fraxAmount);

        vm.prank(owner);
        amo.mintFyFrax(series0Id, fraxAmount);
    }
}

contract YieldSpaceAMO_WithDebt is WithDebtAndFyFraxInAMO {
    function testUnit_burnFyFrax_repay() public {
        console.log("burnFyFrax() repays debt if it can");
        uint128 fyFraxAmount = 10_000 * 1e18;

        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo)));

        // burn some fyFrax, repaying debt
        vm.prank(owner);
        amo.burnFyFrax(series0Id, fyFraxAmount);

        require(uint256(fyToken0.balanceOf(address(amo))) == fyAmoBefore - fyFraxAmount);
        require(uint256(base.balanceOf(address(amo))) == baseAmoBefore + fyFraxAmount);

        // check view fns
        uint256[6] memory expectedAllocations = [
            baseAmoBefore + fyFraxAmount, // [0] fraxInContract: unallocated fees
            fyAmoBefore - fyFraxAmount, // [1] fraxAsCollateral: Frax used as collateral
            0, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            fyAmoBefore - fyFraxAmount, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            0 // [5] LPOwned: number of LP tokens
        ];
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                60_000 * 1e18, // expectedAmount_fraxValue
                1_000_000 * 1e18, // expectedFraxAmount_currentFrax
                1_000_000 * 1e18 // expectedValueAsFrax_dollarBalances
            )
        );
    }

    function testUnit_burnFyFrax_store() public {
        console.log("burnFyFrax() only burns up to the debt limit");
        uint128 extraFyFraxAmount = 10_000 * 1e18;

        (bytes12 vaultId, , , ) = amo.series(series0Id);
        (uint128 debt, ) = yield.balances(vaultId);
        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));

        fyToken0.mint(address(amo), extraFyFraxAmount);
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo)));
        require(debt + extraFyFraxAmount == fyAmoBefore);

        // try burning all fyFrax, but stop when all debt is repaid
        vm.prank(owner);
        amo.burnFyFrax(series0Id, uint128(fyAmoBefore));

        require(uint256(fyToken0.balanceOf(address(amo))) == extraFyFraxAmount);
        require(uint256(base.balanceOf(address(amo))) == baseAmoBefore + debt);

        // check view fns
        uint256[6] memory expectedAllocations = [
            1_000_000 * 1e18, // [0] fraxInContract: unallocated fees
            0, // [1] fraxAsCollateral: Frax used as collateral
            0, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            uint256(extraFyFraxAmount), // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            0 // [5] LPOwned: number of LP tokens
        ];
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                0, // expectedAmount_fraxValue
                1_000_000 * 1e18, // expectedFraxAmount_currentFrax
                1_000_000 * 1e18 // expectedValueAsFrax_dollarBalances
            )
        );
    }
}

abstract contract WithMatureFyFrax is WithDebtAndFyFraxInAMO {
    function setUp() public virtual override {
        super.setUp();

        vm.warp(pool0.maturity() + 1);
    }
}

contract YieldSpaceAMO_WithMatureFyFrax is WithMatureFyFrax {
    function testUnit_burnFyFrax_mature() public {
        console.log("burnFyFrax() abandons debt and redeems after maturity");
        uint128 fyFraxAmount = 10_000 * 1e18;

        (bytes12 vaultId, , , ) = amo.series(series0Id);
        (uint128 debtBefore, ) = yield.balances(vaultId); // 50000000000000000000000
        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));
        fyToken0.mint(address(amo), fyFraxAmount); // This could be avoided if we make this a new state from some that has fyFrax in the AMO
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo))); // 10_000 * 1e18

        // burn some fyFrax, which should be redeemed
        vm.prank(owner);
        amo.burnFyFrax(series0Id, fyFraxAmount);

        require(uint256(fyToken0.balanceOf(address(amo))) == fyAmoBefore - fyFraxAmount);
        require(uint256(base.balanceOf(address(amo))) == baseAmoBefore + fyFraxAmount);
        (uint128 debt, ) = yield.balances(vaultId);
        require(debt == debtBefore);

        // check view fns
        uint256[6] memory expectedAllocations = [
            uint256(fyFraxAmount), // [0] fraxInContract: unallocated fees
            debt, // [1] fraxAsCollateral: Frax used as collateral
            0, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            debt, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            0 // [5] LPOwned: number of LP tokens
        ];
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                60_000 * 1e18, // expectedAmount_fraxValue
                fyFraxAmount + 1_000_000 * 1e18, // expectedFraxAmount_currentFrax
                fyFraxAmount + 1_000_000 * 1e18 // expectedValueAsFrax_dollarBalances
            )
        );
    }
}

abstract contract WithLiquidityAddedToAMM is WithTwoSeriesAdded {
    function setUp() public virtual override {
        super.setUp();
        uint128 fraxAmount = 1_000_000 * 1e18;
        uint256 expectedLpTokens = 1_000_000 * 1e18;
        base.mint(address(amo), fraxAmount);

        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, 0, 0, 1);
    }
}

contract YieldSpaceAMO_WithLiquidityAddedToAMM is WithLiquidityAddedToAMM {
    /* addLiquidity()
     ******************************************************************************************************************/

    function testUnit_addLiquidity() public {
        console.log("addLiquidity() can add more liquidity to AMM with frax and borrowing fyFrax");

        uint256 priorAMOLPTokenBalance = pool0.balanceOf(address(amo));
        uint256 priorPoolBaseBalance = base.balanceOf(address(pool0));

        uint128 fraxAmount = 50_000 * 1e18;
        uint128 fyFraxAmount = 50_000 * 1e18;
        uint256 expectedLpTokens = 50_000 * 1e18;
        base.mint(address(amo), fraxAmount + fyFraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);

        require(pool0.balanceOf(address(amo)) == expectedLpTokens + priorAMOLPTokenBalance);
        require(fyToken0.balanceOf(address(amo)) == 0);
        require(base.balanceOf(address(amo)) == 0);
        require(base.balanceOf(address(pool0)) == fraxAmount + priorPoolBaseBalance);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool0.getCache();
        require(baseCached == fraxAmount + priorPoolBaseBalance);
        require(fyTokenCached == priorAMOLPTokenBalance + expectedLpTokens); // "virtual fyToken balance" 1m + 50k
    }

    function testUnit_addLiquidity_preExistingFyFrax() public {
        console.log("addLiquidity() can add more liquidity to AMM when AMO holds fyFrax");

        uint256 priorAMOLPTokenBalance = pool0.balanceOf(address(amo));
        uint256 priorPoolBaseBalance = base.balanceOf(address(pool0));

        // extra fyTokens in pool
        uint256 preExistingFyTokens = 10_000;
        fyToken0.mint(address(amo), preExistingFyTokens);

        // user plans to call addLiquidity
        uint128 fraxAmount = 50_000 * 1e18;
        uint128 fyFraxAmount = 50_000 * 1e18;
        uint256 expectedLpTokens = 50_000 * 1e18;
        // send over frax to cover fraxAmount and fyFraxAmount
        base.mint(address(amo), fraxAmount + fyFraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);

        require(pool0.balanceOf(address(amo)) == expectedLpTokens + priorAMOLPTokenBalance);
        require(base.balanceOf(address(pool0)) == fraxAmount + priorPoolBaseBalance);
        require(fyToken0.balanceOf(address(amo)) == 0);
        require(base.balanceOf(address(amo)) == preExistingFyTokens);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool0.getCache();
        require(baseCached == fraxAmount + priorPoolBaseBalance);
        require(fyTokenCached == priorAMOLPTokenBalance + expectedLpTokens); // "virtual fyToken balance" 1m + 50k
    }

    function testUnit_addLiquidity_preExistingFrax() public {
        console.log("addLiquidity() can add more liquidity to AMM when AMO holds frax");
        uint256 priorAMOLPTokenBalance = pool0.balanceOf(address(amo));
        uint256 priorPoolBaseBalance = base.balanceOf(address(pool0));

        // extra fyTokens in pool
        uint256 preExistingFrax = 10_000;
        base.mint(address(amo), preExistingFrax);

        // user plans to call addLiquidity
        uint128 fraxAmount = 50_000 * 1e18;
        uint128 fyFraxAmount = 50_000 * 1e18;
        uint256 expectedLpTokens = 50_000 * 1e18;
        // send over frax to cover fraxAmount and fyFraxAmount
        base.mint(address(amo), fraxAmount + fyFraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);

        require(pool0.balanceOf(address(amo)) == expectedLpTokens + priorAMOLPTokenBalance);
        require(base.balanceOf(address(pool0)) == fraxAmount + priorPoolBaseBalance);
        require(fyToken0.balanceOf(address(amo)) == 0);
        require(base.balanceOf(address(amo)) == preExistingFrax);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool0.getCache();
        require(baseCached == fraxAmount + priorPoolBaseBalance);
        require(fyTokenCached == priorAMOLPTokenBalance + expectedLpTokens); // "virtual fyToken balance" 1m + 50k
    }

    function testUnit_addLiquidity_preExistingFraxAndFyFrax() public {
        console.log("addLiquidity() can add more liquidity to AMM when AMO holds both frax and fyFrax");
        uint256 priorAMOLPTokenBalance = pool0.balanceOf(address(amo));
        uint256 priorPoolBaseBalance = base.balanceOf(address(pool0));

        // extra fyTokens in pool
        uint256 preExistingFrax = 5_000;
        base.mint(address(amo), preExistingFrax);
        uint256 preExistingFyFrax = 5_000;
        fyToken0.mint(address(amo), preExistingFrax);

        // user plans to call addLiquidity
        uint128 fraxAmount = 50_000 * 1e18;
        uint128 fyFraxAmount = 50_000 * 1e18;
        uint256 expectedLpTokens = 50_000 * 1e18;
        // send over frax to cover fraxAmount and fyFraxAmount
        base.mint(address(amo), fraxAmount + fyFraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series0Id, fraxAmount, fyFraxAmount, 0, 1);

        require(pool0.balanceOf(address(amo)) == expectedLpTokens + priorAMOLPTokenBalance);
        require(base.balanceOf(address(pool0)) == fraxAmount + priorPoolBaseBalance);
        require(fyToken0.balanceOf(address(amo)) == 0);
        require(base.balanceOf(address(amo)) == 10_000);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool0.getCache();
        require(baseCached == fraxAmount + priorPoolBaseBalance);
        require(fyTokenCached == priorAMOLPTokenBalance + expectedLpTokens); // 1m + 50k "virtual fyToken balance"
    }

    function testUnit_addLiquidityToAMM_secondPool() public {
        console.log("addLiquidity() can add more liquidity to a second pool");

        uint128 fraxAmount = 1_000_000 * 1e18;
        uint256 expectedLpTokens = 1_000_000 * 1e18;
        base.mint(address(amo), fraxAmount);

        vm.expectEmit(false, false, false, true);
        emit LiquidityAdded(fraxAmount, expectedLpTokens);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.addLiquidityToAMM(series1Id, fraxAmount, 0, 0, 1);

        require(pool1.balanceOf(address(amo)) == expectedLpTokens);
        require(base.balanceOf(address(pool1)) == fraxAmount);
        (uint112 baseCached, uint112 fyTokenCached, ) = pool1.getCache();
        require(baseCached == fraxAmount);
        require(fyTokenCached == expectedLpTokens); // "virtual fyToken balance"

        // check view fns
        uint256[6] memory expectedAllocations = [
            uint256(0), // [0] fraxInContract: unallocated fees
            0, // [1] fraxAsCollateral: Frax used as collateral
            fraxAmount, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            0, // [4] fyFraxInLP: fyFrax our LP can claim
            expectedLpTokens // [5] LPOwned: number of LP tokens
        ];

        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                0, // fyFraxAmount_fraxValue
                0, // expectedAmount_fraxValue
                fraxAmount * 2, // expectedFraxAmount_currentFrax
                fraxAmount * 2 // expectedValueAsFrax_dollarBalances
            )
        );
    }

    /* increaseRates()
     ******************************************************************************************************************/
    function testUnit_increaseRates() public {
        console.log("increaseRates() can increase rates");
        uint128 fraxAmount = 50_000 * 1e18;

        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));
        uint256 basePool0Before = uint256(base.balanceOf(address(pool0)));
        uint256 poolAmoBefore = uint256(pool0.balanceOf(address(amo)));
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo)));
        uint256 fyPool0Before = uint256(fyToken0.balanceOf(address(pool0)));
        (uint112 baseCachedBefore, uint112 fyTokenCachedBefore, ) = pool0.getCache();
        uint256 oldRatio = (uint256(fyTokenCachedBefore) * 1e18) / uint256(baseCachedBefore);

        uint128 expectedFyTokenIn = pool0.sellFYTokenPreview(fraxAmount);

        base.mint(address(amo), fraxAmount);
        vm.expectEmit(false, false, false, true);
        emit RatesIncreased(fraxAmount, expectedFyTokenIn);
        vm.prank(owner);
        amo.increaseRates(series0Id, fraxAmount, 49_500 * 1e18);

        (uint112 baseCachedAfter, uint112 fyTokenCachedAfter, ) = pool0.getCache();
        require(baseCachedAfter == baseCachedBefore - expectedFyTokenIn);
        require(fyTokenCachedAfter == fyTokenCachedBefore + fraxAmount);
        require((uint256(fyTokenCachedAfter) * 1e18) / uint256(baseCachedAfter) > oldRatio); // rates increased
        require(uint256(base.balanceOf(address(amo))) == expectedFyTokenIn);
        require(uint256(base.balanceOf(address(pool0))) == basePool0Before - expectedFyTokenIn);
        require(uint256(pool0.balanceOf(address(amo))) == poolAmoBefore);
        require(uint256(fyToken0.balanceOf(address(amo))) == 0);
        require(uint256(fyToken0.balanceOf(address(pool0))) == fyPool0Before + fraxAmount);

        // check view fns
        uint256[6] memory expectedAllocations = [
            expectedFyTokenIn, // [0] fraxInContract: unallocated fees
            fraxAmount, // [1] fraxAsCollateral: Frax used as collateral
            baseCachedAfter, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            fraxAmount, // [4] fyFraxInLP: fyFrax our LP can claim
            poolAmoBefore // [5] LPOwned: number of LP tokens
        ];
        displayViewFns();
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                50_000 * 1e18 + pool0.sellFYTokenPreview(10_000 * 1e18), // expectedAmount_fraxValue
                fyTokenCachedAfter, // expectedFraxAmount_currentFrax
                fyTokenCachedAfter // expectedValueAsFrax_dollarBalances
            )
        );
    }

    function testUnit_increaseRates_PreExistingFyFrax() public {
        console.log("increaseRates() can increase rates");
        uint128 fraxAmount = 50_000 * 1e18;

        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));
        uint256 basePool0Before = uint256(base.balanceOf(address(pool0)));
        uint256 poolAmoBefore = uint256(pool0.balanceOf(address(amo)));
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo)));
        uint256 fyPool0Before = uint256(fyToken0.balanceOf(address(pool0)));
        (uint112 baseCachedBefore, uint112 fyTokenCachedBefore, ) = pool0.getCache();
        uint256 oldRatio = (uint256(fyTokenCachedBefore) * 1e18) / uint256(baseCachedBefore);
        uint128 preExistingFyTokens = 10_000 * 1e18;

        uint128 expectedFyTokenIn = pool0.sellFYTokenPreview(fraxAmount);

        // send extra fyTokens in pool
        fyToken0.mint(address(amo), preExistingFyTokens);

        base.mint(address(amo), fraxAmount);
        vm.expectEmit(false, false, false, true);
        emit RatesIncreased(fraxAmount, expectedFyTokenIn);
        vm.prank(owner);
        amo.increaseRates(series0Id, fraxAmount, 49_500 * 1e18);

        (uint112 baseCachedAfter, uint112 fyTokenCachedAfter, ) = pool0.getCache();
        require(baseCachedAfter == baseCachedBefore - expectedFyTokenIn);
        require(fyTokenCachedAfter == fyTokenCachedBefore + fraxAmount);
        require((uint256(fyTokenCachedAfter) * 1e18) / uint256(baseCachedAfter) > oldRatio); // rates increased
        require(uint256(base.balanceOf(address(amo))) == expectedFyTokenIn + preExistingFyTokens);
        require(uint256(base.balanceOf(address(pool0))) == basePool0Before - expectedFyTokenIn);
        require(uint256(pool0.balanceOf(address(amo))) == poolAmoBefore);
        require(uint256(fyToken0.balanceOf(address(amo))) == 0);
        require(uint256(fyToken0.balanceOf(address(pool0))) == fyPool0Before + fraxAmount);

        // check view fns
        uint256[6] memory expectedAllocations = [
            expectedFyTokenIn + preExistingFyTokens, // [0] fraxInContract: unallocated fees
            40_000 * 1e18, // [1] fraxAsCollateral: Frax used as collateral
            baseCachedAfter, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            fraxAmount, // [4] fyFraxInLP: fyFrax our LP can claim
            poolAmoBefore // [5] LPOwned: number of LP tokens
        ];

        uint256 expectedCurrentFrax = uint256(base.balanceOf(address(amo))) +
            uint256(base.balanceOf(address(pool0))) +
            40_000 *
            1e18 +
            pool0.sellFYTokenPreview(10_000 * 1e18);
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                40_000 * 1e18 + pool0.sellFYTokenPreview(20_000 * 1e18), // expectedAmount_fraxValue
                expectedCurrentFrax, // expectedFraxAmount_currentFrax
                expectedCurrentFrax // expectedValueAsFrax_dollarBalances
            )
        );
    }
}

abstract contract WithRatesIncreased is WithLiquidityAddedToAMM {

    uint256[6] public showAllocations;
    uint256 public fraxValue1_000_000_000_000;
    uint256 public currentFrax;
    uint256 public dollarBalances_valueAsFrax;
    uint256 public dollarBalances_valueAsCollateral;
    function setUp() public virtual override {
        super.setUp();
        uint128 fraxAmount = 50_000 * 1e18;

        base.mint(address(amo), fraxAmount);
        vm.prank(owner);
        amo.increaseRates(series0Id, fraxAmount, 49_500 * 1e18);

        showAllocations = amo.showAllocations(series0Id);
        fraxValue1_000_000_000_000 = amo.fraxValue(series0Id, 1_000_000_000_000 * 1e18);
        currentFrax = amo.currentFrax();
        (dollarBalances_valueAsFrax, dollarBalances_valueAsCollateral) = amo.dollarBalances();

    }
}

contract YieldSpaceAMO_WithRatesIncreased is WithRatesIncreased {
    /* decreaseRates()
     ******************************************************************************************************************/
    function testUnit_decreaseRates() public {
        console.log("decreaseRates() can decrease rates");
        uint128 fraxAmount = 10_000 * 1e18;

        uint256 baseAmoBefore = uint256(base.balanceOf(address(amo)));
        uint256 basePool0Before = uint256(base.balanceOf(address(pool0)));
        uint256 poolAmoBefore = uint256(pool0.balanceOf(address(amo)));
        uint256 fyAmoBefore = uint256(fyToken0.balanceOf(address(amo)));
        uint256 fyPool0Before = uint256(fyToken0.balanceOf(address(pool0)));
        (uint112 baseCachedBefore, uint112 fyTokenCachedBefore, ) = pool0.getCache();
        uint256 oldRatio = (uint256(fyTokenCachedBefore) * 1e18) / uint256(baseCachedBefore);
        uint128 expectedFyTokenIn = pool0.sellBasePreview(fraxAmount);

        // send over fraxamount and call decrease rates
        base.mint(address(amo), fraxAmount);
        vm.expectEmit(false, false, false, true);
        emit RatesDecreased(fraxAmount, expectedFyTokenIn);
        vm.prank(owner);
        amo.decreaseRates(series0Id, fraxAmount, 9_500 * 1e18);

        (uint112 baseCachedAfter, uint112 fyTokenCachedAfter, ) = pool0.getCache();
        require(baseCachedAfter == baseCachedBefore + fraxAmount);
        require(fyTokenCachedAfter == fyTokenCachedBefore - expectedFyTokenIn);
        require((uint256(fyTokenCachedAfter) * 1e18) / uint256(baseCachedAfter) < oldRatio); // rates decreased
        require(uint256(fyToken0.balanceOf(address(amo))) == 0);
        require(uint256(base.balanceOf(address(amo))) == baseAmoBefore + expectedFyTokenIn);
        require(uint256(base.balanceOf(address(pool0))) == basePool0Before + fraxAmount);
        require(uint256(pool0.balanceOf(address(amo))) == poolAmoBefore);
        require(uint256(fyToken0.balanceOf(address(pool0))) == fyPool0Before - expectedFyTokenIn);

        // check view fns
        uint256 debt = fyTokenCachedAfter - pool0.totalSupply();
        uint256[6] memory expectedAllocations = [
            baseAmoBefore + expectedFyTokenIn, // [0] fraxInContract: unallocated fees
            debt, // [1] fraxAsCollateral: Frax used as collateral
            baseCachedAfter, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            debt, // [4] fyFraxInLP: fyFrax our LP can claim
            poolAmoBefore // [5] LPOwned: number of LP tokens
        ];
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                debt + pool0.sellFYTokenPreview(uint128(60_000 * 1e18 - debt)), // expectedAmount_fraxValue
                fyTokenCachedBefore + 10_000 * 1e18, // expectedFraxAmount_currentFrax
                fyTokenCachedBefore + 10_000 * 1e18 // expectedValueAsFrax_dollarBalances
            )
        );
    }

    /* removeLiquidity()
     ******************************************************************************************************************/
    function testReverts_removeLiquidity_SeriesNotFound() public {
        console.log("removeLiquidityFromAMM() reverts if series not found");
        vm.expectRevert("Series not found");
        vm.prank(owner);
        amo.removeLiquidityFromAMM(bytes6(0x000000b0ffed), 1, 0, 1);
    }

    function testUnit_removeLiquidityFromAMM() public {
        console.log("removeLiquidity() can remove liquidity from the AMM");
        uint256 priorAMOLPTokenBalance = pool0.balanceOf(address(amo));
        uint256 priorPoolBaseBalance = base.balanceOf(address(pool0));
        (uint112 baseCachedBefore, uint112 fyTokenCachedBefore, ) = pool0.getCache();

        uint256 lpTokensToRemove = 10_000 * 1e18;

        vm.expectEmit(false, false, false, true);
        emit LiquidityRemoved(lpTokensToRemove / 20, lpTokensToRemove);
        vm.prank(owner);
        (uint256 fraxUsed, uint256 poolMinted) = amo.removeLiquidityFromAMM(
            series0Id,
            lpTokensToRemove,
            1900 * 1e16,
            1905 * 1e16
        );
        require(pool0.balanceOf(address(amo)) == priorAMOLPTokenBalance - lpTokensToRemove);
        require(fyToken0.balanceOf(address(amo)) == 0);

        // check view fns
        (uint112 baseCachedAfter, uint112 fyTokenCachedAfter, ) = pool0.getCache();
        uint256 debt = fyTokenCachedAfter - pool0.totalSupply();
        uint256[6] memory expectedAllocations = [
            base.balanceOf(address(amo)), // [0] fraxInContract: unallocated fees
            debt, // [1] fraxAsCollateral: Frax used as collateral
            baseCachedAfter, // [2] fraxInLP: The Frax our LP tokens can lay claim to
            0, // [3] fyFraxInContract: fyFrax sitting in AMO, should be 0
            debt, // [4] fyFraxInLP: fyFrax our LP can claim
            pool0.balanceOf(address(amo)) // [5] LPOwned: number of LP tokens
        ];
        checkViews(
            CheckViewsParams(
                series0Id, // seriesId_showAllocations
                expectedAllocations, // expected_showAllocations
                series0Id, // seriesId_fraxValue
                60_000 * 1e18, // fyFraxAmount_fraxValue
                49_500 * 1e18 + pool0.sellFYTokenPreview(uint128(10_500 * 1e18)), // expectedAmount_fraxValue
                1_050_000 * 1e18, // expectedFraxAmount_currentFrax
                1_050_000 * 1e18 // expectedValueAsFrax_dollarBalances
            )
        );
    }

    /* warp to maturity and check view fns
     ******************************************************************************************************************/
    function testUnit_checkViewFnsAtMaturity() public {
        console.log("view functions should return correct info after maturity");
        // return values for all of the view fns were stored in state in the WithRatesIncreased abstract contract

        // we first confirm the cached values  reflect the current return values
        uint256[6] memory allocations = amo.showAllocations(series0Id);
        require(allocations[0] == showAllocations[0]);
        require(allocations[1] == showAllocations[1]);
        require(allocations[2] == showAllocations[2]);
        require(allocations[3] == showAllocations[3]);
        require(allocations[4] == showAllocations[4]);
        require(allocations[5] == showAllocations[5]);
        require(amo.fraxValue(series0Id, 1_000_000_000_000 * 1e18) == fraxValue1_000_000_000_000);
        require(amo.currentFrax() == currentFrax);
        (uint256 valueAsFrax, uint256 valueAsCollateral) = amo.dollarBalances();
        require(valueAsFrax == dollarBalances_valueAsFrax);
        require(valueAsCollateral == dollarBalances_valueAsCollateral);

        // then we warp forward to the pool0 maturity date
        vm.warp(pool0.maturity() + 1);

        // then we check the values again, showAllocations() should return the same as above (what was previously cached)
        allocations = amo.showAllocations(series0Id);
        require(allocations[0] == showAllocations[0]);
        require(allocations[1] == showAllocations[1]);
        require(allocations[2] == showAllocations[2]);
        require(allocations[3] == showAllocations[3]);
        require(allocations[4] == showAllocations[4]);
        require(allocations[5] == showAllocations[5]);

        // The only one which will change is the return value of fraxValue(seriesId, amount) on a high amount.
        // Previously (before maturity) it would see if it could sell the excess over the debt amount, and
        // if it couldnt sell it then it would just ignore it.
        // But now, since its matured, all fyTokens can be converted to base tokens 1:1 so we expect the return value
        // of the fraxValue of 1 quadrillion fyFrax to be 1 quadrillion frax
        require(amo.fraxValue(series0Id, 1_000_000_000_000 * 1e18) == 1_000_000_000_000 * 1e18);

        // the rest of the return values should return the same as above
        require(amo.currentFrax() == currentFrax);
        (valueAsFrax, valueAsCollateral) = amo.dollarBalances();
        require(valueAsFrax == dollarBalances_valueAsFrax);
        require(valueAsCollateral == dollarBalances_valueAsCollateral);
    }
}
