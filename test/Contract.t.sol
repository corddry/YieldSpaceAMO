// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "forge-std/Test.sol";
import "../lib/yieldspace-v2/contracts/Pool.sol";
import "../lib/yieldspace-v2/contracts/YieldMath.sol";
import "../lib/yield-utils-v2/contracts/token/SafeERC20Namer.sol";
import "./mocks/VaultMock.sol";
import "./mocks/BaseMock.sol";
import "./mocks/FYTokenMock.sol";

contract YieldSpaceAMOTest is Test {
    VaultMock public yield;
    BaseMock public base;
    FYTokenMock public fyToken;
    Pool public pool;
    bytes6 public seriesId = 0x313830370000;
    uint32 public maturity = 1664550000;
    uint256 public ts = "14613551152";
    uint256 public g1 = "13835058055282163712";
    uint256 public g2 = "24595658764946068821";

    function setUp() public {
        yield = new VaultMock();
        base = yield.base();
        yield.addSeries(seriesId, maturity);
        fyToken = yield.series(seriesId).fyToken;
        pool = new Pool(address(base), address(fyToken), ts, g1, g2);
        yield.addPool(seriesId, pool);
    }

    function testExample() public {
        assertTrue(true);
    }
}
