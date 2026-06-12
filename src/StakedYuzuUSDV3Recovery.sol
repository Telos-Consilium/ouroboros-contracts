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
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    address private constant LOST_ADDRESS = 0x0000000000000000000000000000000000000001;
    address private constant RECOVERY_RECEIVER = 0x0000000000000000000000000000000000000002;
    uint256 private constant RECOVERY_AMOUNT = 1;

    uint256 public minDeposit;
    uint256 public minWithdraw;
    uint256 public instantRedeemFeePpm;
    bool public isInstantRedeemEnabled;

    /// @notice Reinitializes the contract for V3 upgrade and runs a one-shot recovery
    /// @param _admin The admin of the contract
    /// @dev Gated to the proxy admin
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize(address _admin) external virtual reinitializer(3) whenPaused {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedReinitializer(msg.sender);
        if (_admin == address(0)) revert InvalidZeroAddress();

        __AccessControlDefaultAdminRules_init(0, _admin);

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(PAUSE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);

        isInstantRedeemEnabled = true;

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

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev The public instant redeem path is gated by `isInstantRedeemEnabled`. Skip-delay
    /// integrations keep instant access while the public path is disabled.
    function canRedeem(address _owner) public view virtual override returns (bool) {
        if (paused()) {
            return false;
        }
        return isInstantRedeemEnabled || integrations[_owner].canSkipRedeemDelay;
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

    function distribute(uint256 assets, uint256 period) public virtual override onlyRole(POOL_MANAGER_ROLE) {
        super.distribute(assets, period);
    }

    function terminateDistribution(address receiver) public virtual override onlyRole(POOL_MANAGER_ROLE) {
        super.terminateDistribution(receiver);
    }

    function rescueTokens(address token, address receiver, uint256 amount)
        public
        virtual
        override
        onlyRole(ADMIN_ROLE)
    {
        super.rescueTokens(token, receiver, amount);
    }

    // slither-disable-next-line pess-strange-setter
    function setRedeemDelay(uint256 newDelay) public virtual override onlyRole(REDEEM_MANAGER_ROLE) {
        super.setRedeemDelay(newDelay);
    }

    // slither-disable-next-line pess-strange-setter
    function setRedeemFee(uint256 newFeePpm) public virtual override onlyRole(FEE_MANAGER_ROLE) {
        super.setRedeemFee(newFeePpm);
    }

    function setIsInstantRedeemEnabled(bool enabled) external virtual onlyRole(REDEEM_MANAGER_ROLE) {
        bool oldValue = isInstantRedeemEnabled;
        isInstantRedeemEnabled = enabled;
        emit UpdatedIsInstantRedeemEnabled(oldValue, enabled);
    }

    function setInstantRedeemFee(uint256 newFeePpm) external virtual onlyRole(FEE_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert FeeTooHigh(newFeePpm, 1e6);
        uint256 oldFee = instantRedeemFeePpm;
        instantRedeemFeePpm = newFeePpm;
        emit UpdatedInstantRedeemFee(oldFee, newFeePpm);
    }

    // slither-disable-next-line pess-strange-setter
    function setFeeReceiver(address newFeeReceiver) public virtual override onlyRole(FEE_MANAGER_ROLE) {
        super.setFeeReceiver(newFeeReceiver);
    }

    function pause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.pause();
    }

    function unpause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.unpause();
    }

    // slither-disable-next-line pess-strange-setter
    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee)
        public
        virtual
        override
        onlyRole(ADMIN_ROLE)
    {
        super.setIntegration(integration, canSkipRedeemDelay, waiveRedeemFee);
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        if (assets < minDeposit) revert UnderMinDeposit(assets, minDeposit);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 assets = previewMint(shares);
        if (assets < minDeposit) revert UnderMinDeposit(assets, minDeposit);
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        if (assets < minWithdraw) revert UnderMinWithdraw(assets, minWithdraw);
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        (uint256 assets,) = _previewRedeemWithFee(shares, _redeemFeePpmFor(_msgSender()));
        if (assets < minWithdraw) revert UnderMinWithdraw(assets, minWithdraw);
        return super.redeem(shares, receiver, _owner);
    }

    function _previewWithdraw(uint256 assets) internal view virtual override returns (uint256, uint256) {
        return _previewWithdrawWithFee(assets, instantRedeemFeePpm);
    }

    function _previewRedeem(uint256 shares) internal view virtual override returns (uint256, uint256) {
        return _previewRedeemWithFee(shares, instantRedeemFeePpm);
    }

    /// @dev Applies `redeemFeePpm` (or 0 if waived), independent of the instant
    /// redeem fee logic.
    function initiateRedeem(uint256 shares, address receiver, address _owner)
        public
        virtual
        override
        returns (uint256, uint256)
    {
        if (receiver == address(0)) revert InvalidZeroAddress();
        uint256 maxShares = maxRedeemOrder(_owner);
        if (shares > maxShares) revert ExceededMaxRedeemOrder(_owner, shares, maxShares);

        address caller = _msgSender();
        uint256 callerFeePpm = integrations[caller].waiveRedeemFee ? 0 : redeemFeePpm;
        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, callerFeePpm);
        uint256 orderId = _initiateRedeem(caller, receiver, _owner, assets, shares, fee);

        emit InitiatedRedeem(caller, receiver, _owner, orderId, assets, shares, fee);

        return (orderId, assets);
    }

    function _redeemFeePpmFor(address account) internal view virtual override returns (uint256) {
        if (integrations[account].waiveRedeemFee) {
            return 0;
        }
        return instantRedeemFeePpm;
    }

    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMin = minDeposit;
        minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMin = minWithdraw;
        minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[46] private __gap;
}
