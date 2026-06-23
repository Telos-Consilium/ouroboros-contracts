// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILPV2} from "./YuzuILPV2.sol";
import {IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";

/**
 * @title YuzuILPV3
 * @notice YuzuILP with a minimum mint amount, per-block/daily throttling on the instant mint path, a
 * tighter daily yield ceiling, and optional share-price bounds on pool updates and distributions
 * @dev yzILP has no instant redeem (only redeem orders), so the redeem throttle and minWithdraw floor
 * never bind here; only the mint side is active. The order path (createRedeemOrder) is unthrottled.
 * THROTTLE_EXEMPT_ROLE holders bypass the throttle. The bounded {updatePool} and {distribute} overloads
 * revert if the resulting share price falls outside the caller-supplied band; the unbounded ones remain.
 */
contract YuzuILPV3 is YuzuILPV2, YuzuMinAmounts, YuzuThrottle, IYuzuILPV3Definitions {
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Maximum daily linear yield rate, in ppm (1% per day)
    uint256 internal constant MAX_DAILY_YIELD_PPM = 10_000;

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @dev Applies the tighter V3 yield ceiling to every pool update, then runs the inherited logic
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        public
        virtual
        override
    {
        if (newDailyLinearYieldRatePpm > MAX_DAILY_YIELD_PPM) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        super.updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    /// @notice Update the pool and revert if the resulting share price leaves the band
    function updatePool(
        uint256 currentPoolSize,
        uint256 newPoolSize,
        uint256 newDailyLinearYieldRatePpm,
        uint256 minSharePrice,
        uint256 maxSharePrice
    ) external virtual {
        updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
        _checkSharePriceWithin(totalAssets(), minSharePrice, maxSharePrice);
    }

    /// @notice Distribute and revert if the projected end-of-distribution share price leaves the band
    function distribute(uint256 assets, uint256 period, uint256 minSharePrice, uint256 maxSharePrice)
        external
        virtual
    {
        distribute(assets, period);
        _checkSharePriceWithin(totalAssets() + assets, minSharePrice, maxSharePrice);
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

    /// @dev Reverts if the share price implied by {totalAssets_} is outside the band. The price is the
    /// asset value of one whole share. Skipped while there are no shares, when no price exists.
    function _checkSharePriceWithin(uint256 totalAssets_, uint256 minSharePrice, uint256 maxSharePrice) internal view {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return;
        }
        uint256 sharePrice = Math.mulDiv(totalAssets_, 10 ** decimals(), _totalSupply);
        if (sharePrice > maxSharePrice) {
            revert SharePriceTooHigh(sharePrice, maxSharePrice);
        }
        if (sharePrice < minSharePrice) {
            revert SharePriceTooLow(sharePrice, minSharePrice);
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
