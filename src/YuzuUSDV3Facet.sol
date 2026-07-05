// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {YuzuV3FacetBase} from "./YuzuV3FacetBase.sol";
import {
    ADMIN_ROLE,
    LIMIT_MANAGER_ROLE,
    NAV_MANAGER_ROLE,
    ORDER_FILLER_ROLE,
    REDEEM_MANAGER_ROLE
} from "./libraries/YuzuV3Constants.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";
import {IYuzuMinAmountsDefinitions, IYuzuNavMarkdownDefinitions} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuV3RouterBase} from "./interfaces/IYuzuV3FacetRouters.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuMinAmountsV3Storage, YuzuNavMarkdownV3Storage, YuzuThrottleV3Storage} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuUSDV3Facet
 * @dev Fee and pricing math reads state through the vault's external interface so every path prices
 * from one implementation; storage writes use the pinned slots below.
 */
contract YuzuUSDV3Facet is
    YuzuV3FacetBase,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions,
    IYuzuNavMarkdownDefinitions
{
    // User actions
    function fillRedeemOrder(uint256 orderId) external {
        _checkRole(ORDER_FILLER_ROLE);
        IYuzuV3RouterBase router = IYuzuV3RouterBase(address(this));
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        Order storage order = $._orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        (uint256 assets, uint256 fee) = _orderValue(router, order.tokens, order.feePpm);

        order.status = OrderStatus.Filled;
        order.assets = assets;
        $._totalPendingOrderSize -= order.tokens;
        $._totalUnfinalizedOrderValue += assets;

        router.__routerBurn(address(this), order.tokens);
        SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, address(this), assets);

        // slither-disable-next-line reentrancy-events
        emit FilledRedeemOrder(msg.sender, order.receiver, order.owner, orderId, assets, order.tokens, fee);
    }

    // Config setters
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    function setMinWithdraw(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minWithdraw;
        $._minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    function setNav(uint256 newNav) external {
        _checkRole(NAV_MANAGER_ROLE);
        if (newNav == 0) {
            revert InvalidNav(newNav);
        }
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
        uint256 currentNav = $._nav;

        uint256 lastUpdate = $._lastUpdate;
        if (lastUpdate != 0) {
            uint256 readyAt = lastUpdate + $._cooldown;
            if (block.timestamp < readyAt) {
                revert NavCooldownActive(block.timestamp, readyAt);
            }
        }

        if (newNav > currentNav) {
            uint256 maxDelta = Math.mulDiv(currentNav, $._stepCapPpm, 1e6);
            uint256 delta = newNav - currentNav;
            if (delta > maxDelta) {
                revert NavStepTooLarge(newNav, currentNav, maxDelta);
            }
        }

        $._nav = newNav;
        $._lastUpdate = block.timestamp;
        emit UpdatedNav(currentNav, newNav);
    }

    function setNavStepCap(uint256 newStepCapPpm) external {
        _checkRole(ADMIN_ROLE);
        if (newStepCapPpm > 1e6) {
            revert InvalidNavStepCap(newStepCapPpm, 1e6);
        }
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
        uint256 oldStepCapPpm = $._stepCapPpm;
        $._stepCapPpm = newStepCapPpm;
        emit UpdatedNavStepCap(oldStepCapPpm, newStepCapPpm);
    }

    function setNavCooldown(uint256 newCooldown) external {
        _checkRole(ADMIN_ROLE);
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
        uint256 oldCooldown = $._cooldown;
        $._cooldown = newCooldown;
        emit UpdatedNavCooldown(oldCooldown, newCooldown);
    }

    function setRedeemFee(uint256 newFeePpm) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemFeePpm();
        _setRedeemFeePpm(newFeePpm);
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    function setRedeemOrderFee(uint256 newFeePpm) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemOrderFeePpm();
        _setRedeemOrderFeePpm(newFeePpm);
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    // Internal
    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minWithdraw;
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    /// @dev New orders must clear the instant-withdraw floor at their current value.
    function _validateOrderValue(IYuzuV3RouterBase router, uint256 tokens, uint256 feePpm) internal view override {
        (uint256 assets,) = _orderValue(router, tokens, feePpm);
        _checkMinWithdraw(assets);
    }
}
