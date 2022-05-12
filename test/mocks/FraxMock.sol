// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import {IFrax} from "../../src/interfaces/IFrax.sol";


contract FraxMock is ERC20Permit("FRAX", "FRAX", 18) {

  uint256 public global_collateral_ratio = 950000; // fp6

  function setGlobalCollateralRatio(uint256 gcr) public {
    global_collateral_ratio = gcr;
  }
  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) public {
    _burn(from, amount);
  }

}