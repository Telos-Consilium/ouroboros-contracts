// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILPV2} from "./YuzuILPV2.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";

/**
 * @title YuzuILPV3
 * @notice YuzuILP with a minimum mint amount and per-block/daily throttling on the instant mint path
 * @dev yzILP has no instant redeem (only redeem orders), so the redeem throttle and minWithdraw floor
 * never bind here; only the mint side is active. The order path (createRedeemOrder) is unthrottled.
 * THROTTLE_EXEMPT_ROLE holders bypass the throttle.
 */
contract YuzuILPV3 is YuzuILPV2, YuzuMinAmounts, YuzuThrottle {
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @inheritdoc YuzuThrottle
    /// @dev THROTTLE_EXEMPT_ROLE keys on the owner or receiver in both the views and the
    /// state-changing paths, the standard ERC-4626 principal. Caller-keying is reserved for
    /// vaults whose integration model is caller-keyed; the proto vaults have none.
    function _isThrottleExempt(address account) internal view override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
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

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (ILP share price is admin-set and unbounded).
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 headroom = super.maxMint(receiver);
        uint256 remaining = _mintThrottleRemaining(receiver);
        uint256 shares = remaining >= type(uint128).max ? headroom : Math.min(headroom, convertToShares(remaining));
        return previewMint(shares) < minDeposit() ? 0 : shares;
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 tokens = super.deposit(assets, receiver);
        _consumeMintThrottle(receiver, assets);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(previewMint(tokens));
        uint256 assets = super.mint(tokens, receiver);
        _consumeMintThrottle(receiver, assets);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 tokens, address receiver, address _owner) public virtual override returns (uint256) {
        (uint256 assets,) = _previewRedeem(tokens);
        _checkMinWithdraw(assets);
        return super.redeem(tokens, receiver, _owner);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
