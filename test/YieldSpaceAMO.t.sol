// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "forge-std/Test.sol";
// import {DataTypes} from "vault-interfaces/DataTypes.sol";
import {Pool} from "yieldspace-v2/contracts/Pool.sol";
import {YieldMath} from "yieldspace-v2/contracts/YieldMath.sol";
import {SafeERC20Namer} from "yield-utils-v2/contracts/token/SafeERC20Namer.sol";
import {VaultMock} from "./mocks/VaultMock.sol";
import {BaseMock} from "./mocks/BaseMock.sol";
import {FYTokenMock} from "./mocks/FYTokenMock.sol";

contract YieldSpaceAMOTest is Test {

    // TODO: Not sure why we have two different structs named Series?
    struct Series {
        bytes12 vaultId; /// @notice The AMO's debt & collateral record for this series
        IFYToken fyToken;
        IPool pool;
        uint96 maturity;
    }

    VaultMock public yield;
    BaseMock public base;
    FYTokenMock public fyToken;
    Pool public pool;
    bytes6 public seriesId = 0x313830370000;
    uint32 public maturity = 1664550000;
    uint256 public ts = 14613551152;
    uint256 public g1 = 13835058055282163712;
    uint256 public g2 = 24595658764946068821;

    function setUp() public {
        yield = new VaultMock();
        base = yield.base();
        yield.addSeries(seriesId, maturity);
        DataTypes.Series memory s = yield.series(seriesId);
        fyToken = s.fyToken;
        pool = new Pool(address(base), address(fyToken), ts, g1, g2);
        yield.addPool(seriesId, pool);
    }

    function testExample() public {
        assertTrue(true);
    }
}
