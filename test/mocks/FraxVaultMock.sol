// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.13;

import "./FYTokenMock.sol";
import "vault-interfaces/ICauldron.sol";
import "vault-interfaces/IFYToken.sol";
import "vault-interfaces/DataTypes.sol";
import "yieldspace-interfaces/IPool.sol";
import "yield-utils-v2/contracts/token/IERC20.sol";

library CauldronMath {
    /// @dev Add a number (which might be negative) to a positive, and revert if the result is negative.
    function add(uint128 x, int128 y) internal pure returns (uint128 z) {
        require (y > 0 || x >= uint128(-y), "Result below zero");
        z = y > 0 ? x + uint128(y) : x - uint128(-y);
    }
}


/// @notice Simplified mock of the Yield Protocol for Frax.
/// This contract is all the Cauldron, Ladle and Join.
contract FraxVaultMock {
    using CauldronMath for uint128;

    ICauldron public immutable cauldron;
    FraxMock public immutable base;

    mapping (bytes6 => DataTypes.Series) public series;
    mapping (bytes12 => DataTypes.Vault) public vaults;
    mapping (bytes12 => DataTypes.Balances) public balances;
    mapping (bytes6 => IPool) public pools;

    uint96 public lastVaultId = 1;

    constructor() {
        cauldron = ICauldron(address(this));
        base = new FraxMock();
    }

    /// @notice Generate a new series and fyToken for the base at the given maturity.
    function addSeries(bytes6 seriesId, uint32 maturity_) external {
        IFYToken fyToken = IFYToken(address(new FYTokenMock(base, maturity_)));
        series[bytes6(seriesId)] = DataTypes.Series({
            fyToken: fyToken,
            maturity: maturity_,
            baseId: 0x000000000000
        });
    }

    /// @notice Add a matching pool for a series.
    function addPool(bytes6 seriesId, IPool pool) external {
        require (series[seriesId].fyToken == pool.fyToken(), "Mismatched fyToken");
        pools[seriesId] = pool;
    }

    /// @notice Create a vault for a given series
    function build(bytes6 seriesId, bytes6, uint8) external returns (bytes12 vaultId, DataTypes.Vault memory vault) {
        vaults[bytes12(lastVaultId++)] = DataTypes.Vault({
            owner: msg.sender,
            seriesId: seriesId,
            ilkId: 0x00000000
        });

        return (bytes12(lastVaultId - 1), vaults[bytes12(lastVaultId - 1)]);
    }

    /// @notice Borrow or repay, with no collateralization checks, and minting or burning base and fyToken instead of transferring.
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external payable {
        if (ink > 0) base.burn(address(this), uint128(ink)); // Simulate taking the base, which is also the collateral
        if (ink < 0) base.mint(to, uint128(-ink));
        balances[vaultId].ink = balances[vaultId].ink.add(ink);
        balances[vaultId].art = balances[vaultId].art.add(art);
        address fyToken = address(series[vaults[vaultId].seriesId].fyToken);
        if (art > 0) FYTokenMock(fyToken).mint(to, uint128(art));
        if (art < 0) FYTokenMock(fyToken).burn(fyToken, uint128(-art));
    }
}
