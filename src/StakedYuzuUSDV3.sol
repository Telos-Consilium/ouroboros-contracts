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
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";
import {IStakedYuzuUSDV3Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV3
 * @notice Staked Yuzu USD V3 implementation.
 */
contract StakedYuzuUSDV3 is
    StakedYuzuUSDV2,
    AccessControlDefaultAdminRulesUpgradeable,
    YuzuThrottle,
    YuzuMinAmounts,
    IStakedYuzuUSDV3Definitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    uint256 public instantRedeemFeePpm;
    bool public isInstantRedeemEnabled;
    uint256 public maxDistributionPpm;
    uint256 public minDistributionPeriod;

    /// @notice Reinitializes the contract after V3 migration.
    /// @param _admin The admin of the contract
    /// @dev Gated to the proxy admin
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize(address _admin) external virtual reinitializer(4) whenPaused {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedReinitializer(msg.sender);
        if (_admin == address(0)) revert InvalidZeroAddress();
        if (owner() != _admin || !hasRole(ADMIN_ROLE, _admin)) revert UnauthorizedReinitializer(_admin);

        isInstantRedeemEnabled = false;
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
        // max uint disables the distribution amount cap; 0 would block all distributions.
        maxDistributionPpm = type(uint256).max;
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

    /// @dev Ownable checks are disabled after AccessControl migration.
    function _checkOwner() internal view override {}

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev Public instant redeem is gated by isInstantRedeemEnabled; skip-delay integrations bypass it.
    function canRedeem(address _owner) public view virtual override returns (bool) {
        if (paused()) {
            return false;
        }
        return isInstantRedeemEnabled || integrations[_owner].canSkipRedeemDelay;
    }

    /// @dev V3 is reached only by upgrading a live vault through the migration chain; a fresh proxy
    /// initialized at V1 against this implementation can never satisfy {reinitialize}'s guards, so
    /// the inherited initializer is disabled.
    // slither-disable-next-line pess-unprotected-initialize
    function initialize(IERC20, string memory, string memory, address, address, uint256) external pure override {
        revert InitializationDisabled();
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

    function distribute(uint256 assets, uint256 period) public virtual override onlyRole(POOL_MANAGER_ROLE) {
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

    function setRedeemDelay(uint256 newDelay) public virtual override onlyRole(REDEEM_MANAGER_ROLE) {
        if (newDelay == 0) {
            revert RedeemDelayTooLow(newDelay, 1);
        }
        super.setRedeemDelay(newDelay);
    }

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

    function setFeeReceiver(address newFeeReceiver) public virtual override onlyRole(ADMIN_ROLE) {
        super.setFeeReceiver(newFeeReceiver);
    }

    function pause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.pause();
    }

    function unpause() public virtual override onlyRole(PAUSE_MANAGER_ROLE) {
        super.unpause();
    }

    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee)
        public
        virtual
        override
        onlyRole(ADMIN_ROLE)
    {
        super.setIntegration(integration, canSkipRedeemDelay, waiveRedeemFee);
    }

    /// @inheritdoc YuzuThrottle
    function _isThrottleExempt(address account) internal view virtual override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
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
        uint256 maxAssets = Math.min(super.maxWithdraw(_owner), throttleMax);
        return maxAssets < minWithdraw() ? 0 : maxAssets;
    }

    /// @inheritdoc StakedYuzuUSDV2
    /// @dev convertToAssets(maxShares) is bounded by totalAssets, and convertToShares(remaining) is only
    /// reached when remaining is below that bound, so neither conversion can overflow
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        uint256 maxShares = super.maxRedeem(_owner);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = convertToAssets(maxShares) <= remaining ? maxShares : convertToShares(remaining);
        (uint256 netAssets,) = _previewRedeemWithFee(shares, _redeemFeePpmFor(_owner));
        return netAssets < minWithdraw() ? 0 : shares;
    }

    /// @inheritdoc StakedYuzuUSDV2
    function maxRedeemOrder(address _owner) public view virtual override returns (uint256) {
        return _maxRedeemOrderFor(_owner);
    }

    function _maxRedeemOrderFor(address _owner) internal view returns (uint256) {
        uint256 maxShares = super.maxRedeemOrder(_owner);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = convertToAssets(maxShares) <= remaining ? maxShares : convertToShares(remaining);
        (uint256 netAssets,) = _previewRedeemWithFee(shares, redeemFeePpm);
        return netAssets < minWithdraw() ? 0 : shares;
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        address caller = _msgSender();
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            // Throttle-exempt callers bypass the mint throttle at execution time.
            if (!_isThrottleExempt(caller) || paused()) {
                revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
            }
            uint256 maxUnthrottled = StakedYuzuUSDV2.maxDeposit(receiver);
            if (assets > maxUnthrottled) {
                revert ERC4626ExceededMaxDeposit(receiver, assets, maxUnthrottled);
            }
            uint256 shares = previewDeposit(assets);
            _deposit(caller, receiver, assets, shares);
            return shares;
        }
        uint256 mintedShares = super.deposit(assets, receiver);
        _consumeMintThrottle(caller, assets);
        return mintedShares;
    }

    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        uint256 assets = previewMint(shares);
        _checkMinDeposit(assets);
        address caller = _msgSender();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            // Throttle-exempt callers bypass the mint throttle at execution time.
            if (!_isThrottleExempt(caller) || paused()) {
                revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
            }
            uint256 maxUnthrottled = StakedYuzuUSDV2.maxMint(receiver);
            if (shares > maxUnthrottled) {
                revert ERC4626ExceededMaxMint(receiver, shares, maxUnthrottled);
            }
            _deposit(caller, receiver, assets, shares);
            return assets;
        }
        uint256 depositedAssets = super.mint(shares, receiver);
        _consumeMintThrottle(caller, depositedAssets);
        return depositedAssets;
    }

    /// @dev The redeem throttle is consumed on the gross outflow (assets plus fee)
    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        uint256 shares = super.withdraw(assets, receiver, _owner);
        address caller = _msgSender();
        _consumeRedeemThrottle(caller, assets + _feeOnRaw(assets, _redeemFeePpmFor(caller)));
        return shares;
    }

    /// @dev The redeem throttle is consumed on the gross outflow (assets plus fee)
    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        address caller = _msgSender();
        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, _redeemFeePpmFor(caller));
        _checkMinWithdraw(assets);
        uint256 assetsOut = super.redeem(shares, receiver, _owner);
        _consumeRedeemThrottle(caller, assetsOut + fee);
        return assetsOut;
    }

    function _previewWithdraw(uint256 assets) internal view virtual override returns (uint256, uint256) {
        return _previewWithdrawWithFee(assets, instantRedeemFeePpm);
    }

    function _previewRedeem(uint256 shares) internal view virtual override returns (uint256, uint256) {
        return _previewRedeemWithFee(shares, instantRedeemFeePpm);
    }

    function initiateRedeem(uint256 shares, address receiver, address _owner)
        public
        virtual
        override
        returns (uint256, uint256)
    {
        if (receiver == address(0)) revert InvalidZeroAddress();
        address caller = _msgSender();
        uint256 maxShares = _maxRedeemOrderFor(_owner);
        if (shares > maxShares) revert ExceededMaxRedeemOrder(_owner, shares, maxShares);

        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, redeemFeePpm);
        _checkMinWithdraw(assets);
        _consumeRedeemThrottle(_owner, assets + fee);
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

    // slither-disable-next-line pess-event-setter
    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinDeposit(newMin);
    }

    // slither-disable-next-line pess-event-setter
    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinWithdraw(newMin);
    }

    /// @notice Cap on a single distribution, in ppm of current totalAssets; type(uint256).max disables it
    function setMaxDistributionPpm(uint256 newMaxPpm) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxPpm = maxDistributionPpm;
        maxDistributionPpm = newMaxPpm;
        emit UpdatedMaxDistributionPpm(oldMaxPpm, newMaxPpm);
    }

    function setMinDistributionPeriod(uint256 newPeriod) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
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

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[46] private __gap;
}
