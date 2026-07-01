// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {StakedYuzuUSDV2} from "./StakedYuzuUSDV2.sol";
import {IStakedYuzuUSDV3Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV3Migration
 * @notice One-time Staked Yuzu USD V3 migration implementation.
 */
contract StakedYuzuUSDV3Migration is
    StakedYuzuUSDV2,
    AccessControlDefaultAdminRulesUpgradeable,
    IStakedYuzuUSDV3Definitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Migrates ownership to AccessControl.
    /// @param _admin The admin of the contract
    /// @dev Gated to the proxy admin so migration can only run through ProxyAdmin.upgradeAndCall.
    // slither-disable-next-line pess-unprotected-initialize
    function migrateToV3(address _admin) external virtual reinitializer(3) whenPaused {
        _migrateToAccessControl(_admin);
    }

    function _migrateToAccessControl(address _admin) internal {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedReinitializer(msg.sender);
        if (_admin == address(0)) revert InvalidZeroAddress();

        __AccessControlDefaultAdminRules_init(0, _admin);

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(PAUSE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);

        _transferOwnership(address(0));
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

    function transferOwnership(address) public pure override(Ownable2StepUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }

    function acceptOwnership() public pure override(Ownable2StepUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }

    function renounceOwnership() public pure override(OwnableUpgradeable) {
        revert OwnershipMigratedToAccessControl();
    }
}
