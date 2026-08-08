// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {StakedYuzuUSDV2} from "./StakedYuzuUSDV2.sol";
import {YuzuV3RestrictedShares} from "./libraries/YuzuV3RestrictedShares.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";
import {IntegrationConfig, IStakedYuzuUSDV3Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";
import {
    ADMIN_ROLE,
    DELAY_EXEMPT_ROLE,
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    PAUSE_MANAGER_ROLE,
    PRICE_GUARD_MANAGER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    REDEEM_MANAGER_ROLE,
    SAME_BLOCK_EXEMPT_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./libraries/YuzuV3Constants.sol";

/**
 * @title StakedYuzuUSDV3
 * @notice Staked Yuzu USD with V3 role-based access control, throttles, and minimum amounts.
 */
// slither-disable-next-line missing-inheritance
contract StakedYuzuUSDV3 is
    StakedYuzuUSDV2,
    AccessControlDefaultAdminRulesUpgradeable,
    YuzuThrottle,
    YuzuMinAmounts,
    IStakedYuzuUSDV3Definitions
{
    uint256 public instantRedeemFeePpm;
    bool public isInstantRedeemEnabled;
    uint256 public maxDistributionPpm;
    uint256 public minDistributionPeriod;
    uint256 public minRedeemOrder;

    // Initialization
    /// @notice Initializes V3 over a V1-initialized vault: migrates ownership to AccessControl
    /// and applies the V3 configuration.
    /// @param _admin The admin of the contract
    /// @dev Gated to the proxy admin.
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize(address _admin) external virtual reinitializer(4) whenPaused {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedReinitializer(msg.sender);
        if (_admin == address(0)) revert InvalidZeroAddress();

        __EIP712_init(name(), "2");
        __AccessControlDefaultAdminRules_init(0, _admin);

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(PAUSE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(DISTRIBUTOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PRICE_GUARD_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SAME_BLOCK_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(DELAY_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_FEE_EXEMPT_ROLE, ADMIN_ROLE);
        _transferOwnership(address(0));

        isInstantRedeemEnabled = false;
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
        minDistributionPeriod = 1 days;
        // max uint disables the distribution amount cap; 0 would block all distributions.
        maxDistributionPpm = type(uint256).max;
    }

    /// @dev The inherited V1 initializer is disabled; fresh deploys initialize at V1 and then
    /// run reinitialize.
    // slither-disable-next-line pess-unprotected-initialize
    function initialize(IERC20, string memory, string memory, address, address, uint256) external pure override {
        revert InitializationDisabled();
    }

    // Ownership migration to AccessControl
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

    /// @dev Ownable checks are no-ops; authorization is role-based.
    function _checkOwner() internal view override {}

    // Views
    /// @inheritdoc StakedYuzuUSDV2
    /// @dev Public instant redeem is gated by isInstantRedeemEnabled; owners holding
    /// DELAY_EXEMPT_ROLE bypass it.
    function canRedeem(address _owner) public view virtual override returns (bool) {
        if (paused()) {
            return false;
        }
        return isInstantRedeemEnabled || hasRole(DELAY_EXEMPT_ROLE, _owner);
    }

    /// @inheritdoc StakedYuzuUSDV2
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev previewDeposit(remaining) <= remaining while totalSupply <= totalAssets (1 share >= 1 asset),
    /// so the asset-to-share conversion cannot overflow for any remaining
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 maxShares = super.maxMint(receiver);
        uint256 remaining = _mintThrottleRemaining(receiver);
        uint256 shares = Math.min(maxShares, previewDeposit(remaining));
        return previewMint(shares) < minDeposit() ? 0 : shares;
    }

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev Reported net of the fee; throttle capacity is denominated in gross outflow
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 throttleMax = remaining - _feeOnTotal(remaining, _redeemFeePpmFor(_owner));
        (uint256 matureMax,) = _previewRedeemWithFee(_matureBalance(_owner), _redeemFeePpmFor(_owner));
        uint256 maxAssets = Math.min(Math.min(super.maxWithdraw(_owner), throttleMax), matureMax);
        return maxAssets < minWithdraw() ? 0 : maxAssets;
    }

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev convertToAssets(maxShares) is bounded by totalAssets, and convertToShares(remaining) is only
    /// reached when remaining is below that bound, so neither conversion can overflow
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        uint256 maxShares = Math.min(super.maxRedeem(_owner), _matureBalance(_owner));
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = convertToAssets(maxShares) <= remaining ? maxShares : convertToShares(remaining);
        (uint256 netAssets,) = _previewRedeemWithFee(shares, _redeemFeePpmFor(_owner));
        return netAssets < minWithdraw() ? 0 : shares;
    }

    /// @inheritdoc StakedYuzuUSDV2
    function maxRedeemOrder(address _owner) public view virtual override returns (uint256) {
        return _maxRedeemOrderFor(_owner);
    }

    // User flows
    /// @dev The mint throttle keys on the receiver, matching {maxDeposit}, so the view and the
    /// execution agree on the same principal. Integrations that rate-limit their own inflow deposit
    /// as the receiver and forward the shares.
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 mintedShares = super.deposit(assets, receiver);
        _consumeMintThrottle(receiver, assets);
        return mintedShares;
    }

    /// @dev The mint throttle keys on the receiver, matching {maxMint}; see {deposit}.
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 assets = previewMint(shares);
        _checkMinDeposit(assets);
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }
        uint256 depositedAssets = super.mint(shares, receiver);
        _consumeMintThrottle(receiver, depositedAssets);
        return depositedAssets;
    }

    /// @dev Self-contained body; the inherited path routes through the integration mapping. Fee,
    /// throttle, and {maxWithdraw} all key on the owner, so the view never overstates and the
    /// throttle books exactly the gross outflow (assets plus fee).
    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssets);
        }
        (uint256 shares, uint256 fee) = _previewWithdrawWithFee(assets, _redeemFeePpmFor(_owner));
        _withdraw(_msgSender(), receiver, _owner, shares, assets, fee);
        _consumeRedeemThrottle(_owner, assets + fee);
        return shares;
    }

    /// @dev Self-contained body; see {withdraw}. Fee, throttle, and {maxRedeem} all key on the
    /// owner.
    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, _redeemFeePpmFor(_owner));
        _checkMinWithdraw(assets);
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
        }
        _withdraw(_msgSender(), receiver, _owner, shares, assets, fee);
        _consumeRedeemThrottle(_owner, assets + fee);
        return assets;
    }

    // slither-disable-next-line pess-unprotected-initialize
    function initiateRedeem(uint256 shares, address receiver, address _owner)
        public
        virtual
        override
        returns (uint256, uint256)
    {
        if (receiver == address(0)) revert InvalidZeroAddress();
        address caller = _msgSender();
        if (shares < minRedeemOrder) revert UnderMinRedeemOrder(shares, minRedeemOrder);
        uint256 maxShares = _maxRedeemOrderFor(_owner);
        if (shares > maxShares) revert ExceededMaxRedeemOrder(_owner, shares, maxShares);

        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, redeemFeePpm);
        _consumeRedeemThrottle(_owner, assets + fee);
        uint256 orderId = _initiateRedeem(caller, receiver, _owner, assets, shares, fee);

        emit InitiatedRedeem(caller, receiver, _owner, orderId, assets, shares, fee);

        return (orderId, assets);
    }

    // Distribution operations
    function distribute(uint256 assets, uint256 period) public virtual override onlyRole(DISTRIBUTOR_ROLE) {
        if (period < minDistributionPeriod) {
            revert DistributionPeriodTooLow(period, minDistributionPeriod);
        }
        if (maxDistributionPpm != type(uint256).max) {
            uint256 maxAssets = Math.mulDiv(totalAssets(), maxDistributionPpm, 1e6);
            if (assets > maxAssets) {
                revert DistributionAmountTooHigh(assets, maxAssets);
            }
        }
        super.distribute(assets, period);
    }

    function terminateDistribution(address receiver) public virtual override onlyRole(DISTRIBUTOR_ROLE) {
        super.terminateDistribution(receiver);
    }

    // Admin
    function rescueTokens(address token, address receiver, uint256 amount)
        public
        virtual
        override
        onlyRole(ADMIN_ROLE)
    {
        super.rescueTokens(token, receiver, amount);
    }

    function setFeeReceiver(address newFeeReceiver) public virtual override onlyRole(ADMIN_ROLE) {
        super.setFeeReceiver(newFeeReceiver);
    }

    function pause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.pause();
    }

    function unpause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.unpause();
    }

    /// @dev Delay and fee exemptions are role-based and nothing reads the integration mapping,
    /// so writes are disabled. The override also seals the inherited onlyOwner entry point,
    /// which the disabled _checkOwner would otherwise leave open.
    function setIntegration(address, bool, bool) public pure override {
        revert IntegrationsMigratedToRoles();
    }

    function getIntegration(address) external pure override returns (IntegrationConfig memory) {
        revert IntegrationsMigratedToRoles();
    }

    // Config setters
    function setRedeemDelay(uint256 newDelay) public virtual override onlyRole(REDEEM_MANAGER_ROLE) {
        if (newDelay == 0) {
            revert RedeemDelayTooLow(newDelay, 1);
        }
        super.setRedeemDelay(newDelay);
    }

    function setRedeemFee(uint256 newFeePpm) public virtual override onlyRole(FEE_MANAGER_ROLE) {
        super.setRedeemFee(newFeePpm);
    }

    function setInstantRedeemFee(uint256 newFeePpm) external virtual onlyRole(FEE_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert FeeTooHigh(newFeePpm, 1e6);
        uint256 oldFee = instantRedeemFeePpm;
        instantRedeemFeePpm = newFeePpm;
        emit UpdatedInstantRedeemFee(oldFee, newFeePpm);
    }

    function setIsInstantRedeemEnabled(bool enabled) external virtual onlyRole(REDEEM_MANAGER_ROLE) {
        bool oldValue = isInstantRedeemEnabled;
        isInstantRedeemEnabled = enabled;
        emit UpdatedIsInstantRedeemEnabled(oldValue, enabled);
    }

    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinDeposit(newMin);
    }

    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinWithdraw(newMin);
    }

    function setMinRedeemOrder(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMin = minRedeemOrder;
        minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }

    /// @notice Cap on a single distribution, in ppm of current totalAssets; type(uint256).max disables it
    function setMaxDistributionPpm(uint256 newMaxPpm) external virtual onlyRole(PRICE_GUARD_MANAGER_ROLE) {
        uint256 oldMaxPpm = maxDistributionPpm;
        maxDistributionPpm = newMaxPpm;
        emit UpdatedMaxDistributionPpm(oldMaxPpm, newMaxPpm);
    }

    function setMinDistributionPeriod(uint256 newPeriod) external virtual onlyRole(PRICE_GUARD_MANAGER_ROLE) {
        if (newPeriod < 1 hours) {
            revert DistributionPeriodTooLow(newPeriod, 1 hours);
        }
        if (newPeriod > 7 days) {
            revert DistributionPeriodTooHigh(newPeriod, 7 days);
        }
        uint256 oldPeriod = minDistributionPeriod;
        minDistributionPeriod = newPeriod;
        emit UpdatedMinDistributionPeriod(oldPeriod, newPeriod);
    }

    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setMintThrottle(newBlockLimit, newDailyLimit);
    }

    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setRedeemThrottle(newBlockLimit, newDailyLimit);
    }

    /// @notice Shares received in the current block, tracked so downstream redeemers can exclude them
    function currentBlockRestrictedBalance(address account) external view returns (uint256) {
        return YuzuV3RestrictedShares.currentBlockRestrictedBalance(account);
    }

    /// @notice Redeem-throttle capacity remaining for {account}, in asset terms; max for THROTTLE_EXEMPT_ROLE accounts
    function redeemThrottleRemaining(address account) external view returns (uint256) {
        return _redeemThrottleRemaining(account);
    }

    // Internal
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        YuzuV3RestrictedShares.update(from, to, value, balanceOf(from));
    }

    /// @inheritdoc YuzuThrottle
    function _isThrottleExempt(address account) internal view virtual override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _isSameBlockExempt(address account) private view returns (bool) {
        return hasRole(SAME_BLOCK_EXEMPT_ROLE, account);
    }

    /// @dev Share balance eligible under the same-block guard; excludes shares received in the current
    /// block unless the owner has SAME_BLOCK_EXEMPT_ROLE.
    function _matureBalance(address _owner) private view returns (uint256) {
        if (_isSameBlockExempt(_owner)) {
            return balanceOf(_owner);
        }
        return balanceOf(_owner) - YuzuV3RestrictedShares.currentBlockRestrictedBalance(_owner);
    }

    function _maxRedeemOrderFor(address _owner) internal view returns (uint256) {
        uint256 maxShares = super.maxRedeemOrder(_owner);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = convertToAssets(maxShares) <= remaining ? maxShares : convertToShares(remaining);
        return shares < minRedeemOrder ? 0 : shares;
    }

    function _previewWithdraw(uint256 assets) internal view virtual override returns (uint256, uint256) {
        return _previewWithdrawWithFee(assets, instantRedeemFeePpm);
    }

    function _previewRedeem(uint256 shares) internal view virtual override returns (uint256, uint256) {
        return _previewRedeemWithFee(shares, instantRedeemFeePpm);
    }

    function _redeemFeePpmFor(address account) internal view virtual override returns (uint256) {
        if (hasRole(REDEEM_FEE_EXEMPT_ROLE, account)) {
            return 0;
        }
        return instantRedeemFeePpm;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[45] private __gap;
}
