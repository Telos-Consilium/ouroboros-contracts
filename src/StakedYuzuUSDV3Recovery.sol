// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {StakedYuzuUSDV2} from "./StakedYuzuUSDV2.sol";
import {IStakedYuzuUSDV3Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV3Recovery
 * @notice StakedYuzuUSD migrated from Ownable2Step to AccessControl for parity with yzUSD/yzPP
 * @dev `_checkOwner()` is neutralized so inherited `onlyOwner` no longer gates. Every owner-gated
 * function from V1/V2 is re-gated here with `onlyRole(...)`.
 */
contract StakedYuzuUSDV3Recovery is
    StakedYuzuUSDV2,
    AccessControlDefaultAdminRulesUpgradeable,
    IStakedYuzuUSDV3Definitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    address private constant LOST_ADDRESS = 0x0000000000000000000000000000000000000001;
    address private constant RECOVERY_RECEIVER = 0x0000000000000000000000000000000000000002;
    uint256 private constant RECOVERY_AMOUNT = 1;

    /// @notice Reinitializes the contract for V3 upgrade and runs a one-shot recovery
    /// @param _admin The admin of the contract
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize(address _admin) external virtual reinitializer(3) whenPaused {
        __AccessControlDefaultAdminRules_init(0, _admin);

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(PAUSE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);

        // Clear Ownable2Step state
        _transferOwnership(address(0));

        // Run recovery
        _burn(LOST_ADDRESS, RECOVERY_AMOUNT);
        _mint(RECOVERY_RECEIVER, RECOVERY_AMOUNT);
        emit Recovered(LOST_ADDRESS, RECOVERY_RECEIVER, RECOVERY_AMOUNT);
    }

    /// @inheritdoc AccessControlDefaultAdminRulesUpgradeable
    function owner()
        public
        view
        virtual
        override(OwnableUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
        returns (address)
    {
        return AccessControlDefaultAdminRulesUpgradeable.owner();
    }

    /// @dev Neutralized
    function _checkOwner() internal view override {}

    function distribute(uint256 assets, uint256 period) public override onlyRole(POOL_MANAGER_ROLE) {
        super.distribute(assets, period);
    }

    function terminateDistribution(address receiver) public override onlyRole(POOL_MANAGER_ROLE) {
        super.terminateDistribution(receiver);
    }

    function rescueTokens(address token, address receiver, uint256 amount) public override onlyRole(ADMIN_ROLE) {
        super.rescueTokens(token, receiver, amount);
    }

    // slither-disable-next-line pess-strange-setter
    function setRedeemDelay(uint256 newDelay) public override onlyRole(REDEEM_MANAGER_ROLE) {
        super.setRedeemDelay(newDelay);
    }

    // slither-disable-next-line pess-strange-setter
    function setRedeemFee(uint256 newFeePpm) public override onlyRole(REDEEM_MANAGER_ROLE) {
        super.setRedeemFee(newFeePpm);
    }

    // slither-disable-next-line pess-strange-setter
    function setFeeReceiver(address newFeeReceiver) public override onlyRole(ADMIN_ROLE) {
        super.setFeeReceiver(newFeeReceiver);
    }

    function pause() public override onlyRole(PAUSE_MANAGER_ROLE) {
        super.pause();
    }

    function unpause() public override onlyRole(PAUSE_MANAGER_ROLE) {
        super.unpause();
    }

    // slither-disable-next-line pess-strange-setter
    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee)
        public
        override
        onlyRole(ADMIN_ROLE)
    {
        super.setIntegration(integration, canSkipRedeemDelay, waiveRedeemFee);
    }

    function transferOwnership(address) public override(Ownable2StepUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }

    function acceptOwnership() public override(Ownable2StepUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }

    function renounceOwnership() public override(OwnableUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
