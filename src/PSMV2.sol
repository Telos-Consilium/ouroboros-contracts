// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PSM} from "./PSM.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuSameBlockGuard} from "./proto/YuzuSameBlockGuard.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";

/**
 * @title PSMV2
 * @notice PSM with V2 limits, throttles, and same-block guard
 * @dev Throttles and same-block checks apply only to instant deposit and redeem paths.
 */
contract PSMV2 is PSM, YuzuMinAmounts, YuzuThrottle, YuzuSameBlockGuard {
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Reinitializes the contract for the V2 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV2() external reinitializer(2) {
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @inheritdoc YuzuThrottle
    function _isThrottleExempt(address account) internal view override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    /// @inheritdoc YuzuSameBlockGuard
    function _isSameBlockGuardExempt(address account) internal view override returns (bool) {
        return _isThrottleExempt(account);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setMintThrottle(newBlockLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setRedeemThrottle(newBlockLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinDeposit(newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinWithdraw(newMin);
    }

    /// @inheritdoc PSM
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @inheritdoc PSM
    /// @dev The inverse asset-to-share conversion only runs when the remaining throttle budget is below
    /// the share ceiling's asset value, so it cannot overflow on an unlimited (exempt or max) budget.
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        uint256 maxShares = super.maxRedeem(_owner);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = _previewRedeemAssets(maxShares) <= remaining ? maxShares : _sharesForAssets(remaining);
        return _previewRedeemAssets(shares) < minWithdraw() ? 0 : shares;
    }

    /// @inheritdoc PSM
    /// @dev Not nonReentrant; super holds the guard and the trailing throttle and stamp writes touch only storage.
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 shares = super.deposit(assets, receiver);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver, shares);
        return shares;
    }

    /// @inheritdoc PSM
    /// @dev Not nonReentrant; super holds the guard and the trailing throttle write touches only storage.
    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        _checkSameBlockRedeem(_owner);
        uint256 assetsOut = super.redeem(shares, receiver, _owner);
        _checkMinWithdraw(assetsOut);
        _consumeRedeemThrottle(_owner, assetsOut);
        return assetsOut;
    }

    function _createRedeemOrder(address caller, address receiver, address _owner, uint256 shares)
        internal
        virtual
        override
        returns (uint256)
    {
        _checkMinWithdraw(_previewRedeemAssets(shares));
        return super._createRedeemOrder(caller, receiver, _owner, shares);
    }

    /// @dev Underlying asset value of shares at the fee-waived rate.
    function _previewRedeemAssets(uint256 shares) private view returns (uint256) {
        return _vault0.convertToAssets(_vault1.convertToAssets(shares));
    }

    /// @dev Shares whose redeem yields the given underlying assets.
    function _sharesForAssets(uint256 assets) private view returns (uint256) {
        return _vault1.convertToShares(_vault0.convertToShares(assets));
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
