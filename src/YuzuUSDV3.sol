// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuSameBlockGuard} from "./proto/YuzuSameBlockGuard.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";
import {YuzuUSDV2} from "./YuzuUSDV2.sol";

/**
 * @title YuzuUSDV3
 * @notice YuzuUSD with minimum mint/redeem amounts, per-block/daily throttling, and a same-block
 * mint+redeem guard on the instant paths
 * @dev The throttle and same-block guard gate only the instant deposit/mint and withdraw/redeem paths.
 * The order path (createRedeemOrder) is not gated. THROTTLE_EXEMPT_ROLE holders bypass both.
 */
contract YuzuUSDV3 is YuzuUSDV2, YuzuMinAmounts, YuzuThrottle, YuzuSameBlockGuard {
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @inheritdoc YuzuMinAmounts
    function _authorizeMinAmounts() internal view override {
        _checkRole(LIMIT_MANAGER_ROLE);
    }

    /// @inheritdoc YuzuThrottle
    /// @dev THROTTLE_EXEMPT_ROLE keys on the owner or receiver in both the views and the
    /// state-changing paths, the standard ERC-4626 principal. Caller-keying is reserved for
    /// vaults whose integration model is caller-keyed; the proto vaults have none.
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

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (proto share price is not bounded below 1).
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 headroom = super.maxMint(receiver);
        uint256 remaining = _mintThrottleRemaining(receiver);
        uint256 shares = remaining >= type(uint128).max ? headroom : Math.min(headroom, convertToShares(remaining));
        return previewMint(shares) < minDeposit() ? 0 : shares;
    }

    /// @dev Reported net of the fee; throttle capacity is denominated in gross outflow
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 throttleMax = remaining - _feeOnTotal(remaining, redeemFeePpm);
        uint256 maxAssets = Math.min(super.maxWithdraw(_owner), throttleMax);
        return maxAssets < minWithdraw() ? 0 : maxAssets;
    }

    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        uint256 maxTokens = super.maxRedeem(_owner);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = convertToAssets(maxTokens) <= remaining ? maxTokens : convertToShares(remaining);
        return previewRedeem(shares) < minWithdraw() ? 0 : shares;
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 tokens = super.deposit(assets, receiver);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(previewMint(tokens));
        uint256 assets = super.mint(tokens, receiver);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(_owner);
        uint256 tokens = super.withdraw(assets, receiver, _owner);
        _consumeRedeemThrottle(_owner, assets + _feeOnRaw(assets, redeemFeePpm));
        return tokens;
    }

    function redeem(uint256 tokens, address receiver, address _owner) public virtual override returns (uint256) {
        (uint256 assets, uint256 fee) = _previewRedeem(tokens);
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(_owner);
        uint256 assetsOut = super.redeem(tokens, receiver, _owner);
        _consumeRedeemThrottle(_owner, assetsOut + fee);
        return assetsOut;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
