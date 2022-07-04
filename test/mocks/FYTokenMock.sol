// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import "./FraxMock.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";


contract FYTokenMock is ERC20Permit {
    FraxMock public base;
    uint32 public maturity;

    constructor (FraxMock base_, uint32 maturity_)
        ERC20Permit(
            "fyFRAX",
            "fyFRAX",
            IERC20Metadata(address(base_)).decimals()
    ) {
        base = base_;
        maturity = maturity_;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

        /// @dev Burn fyTokens.
    /// Any tokens locked in this contract will be burned first and subtracted from the amount to burn from the user's wallet.
    /// This feature allows someone to transfer fyToken to this contract to enable a `burn`, potentially saving the cost of `approve` or `permit`.
    function _burn(address from, uint256 amount) internal override returns (bool) {
        // First use any tokens locked in this contract
        uint256 available = _balanceOf[address(this)];
        if (available >= amount) {
            return super._burn(address(this), amount);
        } else {
            if (available > 0) super._burn(address(this), available);
            unchecked {
                _decreaseAllowance(from, amount - available);
            }
            unchecked {
                return super._burn(from, amount - available);
            }
        }
    }

    function mintWithUnderlying(address to, uint256 amount) public {
        _mint(to, amount); // It would be neat to check that the underlying has been sent to the join
    }

    function redeem(address to, uint256 amount) public returns (uint256) {
        _burn(address(this), amount); // redeem would also take the fyToken from msg.sender, but we don't need that here
        base.mint(to, amount);
        return amount;
    }
}