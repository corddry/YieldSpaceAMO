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

import "../Frax/Frax.sol"; //TODO adjust for foundry
import "https://github.com/FraxFinance/frax-contracts-dev/blob/master/src/hardhat/contracts/Staking/Owned.sol";
import "amoMinter";

contract YieldSpaceAMO is Owned {
    /* =========== STATE VARIABLES =========== */
    FRAXStablecoin private immutable FRAX;
    IFraxAMOMinter private immutable amo_minter;

    address public immutable timelock_address;
    address public custodian_address;

    //TODO Do we need a Frax price oracle?

    uint256 public minted_frax_historical = 0;
    uint256 public burned_frax_historical = 0;

    /* ============= CONSTRUCTOR ============= */
    constructor (
        address _owner_address,
        address _amo_minter_address
    ) Owned(_owner_address) {
        FRAX = FRAXStablecoin(0x853d955aCEf822Db058eb8505911ED77F175b99e);
        amo_minter = IFraxAMOMinter(_amo_minter_address);

        // TODO What is custodian? Get the custodian and timelock addresses from the minter
        timelock_address = amo_minter.timelock_address();
        custodian_address = amo_minter.custodian_address();
    }

    /* ============== MODIFIERS ============== */
    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() { //TODO Where use?
        require(msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address, "Not owner, tlck, or custd");
        _;
    }

    modifier onlyByMinter() { //TODO Necessary?
        require(msg.sender == address(amo_minter), "Not minter");
        _;
    }

    /* ================ VIEWS ================ */
    /// @notice returns the total amount of FRAX tokens minted by the AMO
    function totalAMOControlledFRAX() public view returns (uint256) {
    }

    /// @notice returns current rate on Frax debt
    function getRate() public view returns (uint256) { //TODO Name better
    }

    /// @notice returns the collateral balance of the AMO for calculating FRAX’s global collateral ratio
    /// (all AMOs have this function)
    function collatDollarBalance() public view returns (uint256) {
    }

    /// @notice returns the current amount of FRAX that the protocol must pay out on maturity of circulating fyFRAX in the open market
    function debtOutstanding() public view returns (uint256) {
    }

    /* ========= RESTRICTED FUNCTIONS ======== */
    /// @notice mint fyFrax using FRAX as collateral
    function mintFyFrax(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /// @notice burn fyFrax to redeem FRAX collateral
    function burnFyFrax(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /// @notice mint new fyFrax to sell into the AMM to push up rates
    function increaseRates(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /// @notice buy fyFrax from the AMO to push down rates //TODO and burn???
    function decreaseRates(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /// @notice mint fyFrax tokens, pair with FRAX and provide liquidity
    function addLiquidityToAMM(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /// @notice remove liquidity and burn fyTokens //TODO why burn???
    function addLiquidityToAMM(uint256 frax_amount) public view onlyByOwnGovCust returns (uint256) {
    }

    /* === RESTRICTED GOVERNANCE FUNCTIONS === */
    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IFraxAMOMinter(_amo_minter_address);

        // Get the custodian and timelock addresses from the minter
        custodian_address = amo_minter.custodian_address();
        timelock_address = amo_minter.timelock_address();

        // Make sure the new addresses are not address(0)
        require(custodian_address != address(0) && timelock_address != address(0), "Invalid custodian or timelock");
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
