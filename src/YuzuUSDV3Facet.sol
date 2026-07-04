// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IYuzuIssuerDefinitions} from "./interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";
import {
    IYuzuMinAmountsDefinitions,
    IYuzuNavMarkdownDefinitions,
    IYuzuProtoDefinitions
} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuUSDV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuMinAmountsV3Storage, YuzuNavMarkdownV3Storage, YuzuThrottleV3Storage} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuUSDV3Facet
 * @dev Fee and pricing math reads state through the vault's external interface so every path prices
 * from one implementation; storage writes use the pinned slots below.
 */
contract YuzuUSDV3Facet is
    IYuzuIssuerDefinitions,
    IYuzuOrderBookDefinitions,
    IYuzuProtoDefinitions,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions,
    IYuzuNavMarkdownDefinitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");

    uint256 private constant YUZU_PROTO_TREASURY_SLOT = 1;
    uint256 private constant YUZU_PROTO_REDEEM_FEE_SLOT = 2;
    uint256 private constant YUZU_PROTO_REDEEM_ORDER_FEE_SLOT = 3;
    uint256 private constant YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT = 4;
    uint256 private constant IS_MINT_RESTRICTED_SHIFT = 160;
    uint256 private constant IS_REDEEM_RESTRICTED_SHIFT = 168;

    struct YuzuIssuerStorage {
        uint256 _supplyCap;
        uint256 _liquidityBufferTargetSize;
    }

    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _totalPendingOrderSize;
        uint256 _totalUnfinalizedOrderValue;
        uint256 _orderCount;
        uint256 _minRedeemOrder;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation =
        0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    // External
    function createRedeemOrder(uint256 tokens, address receiver, address owner) public returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxTokens = router.maxRedeemOrder(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 minTokens = $._minRedeemOrder;
        if (tokens < minTokens) {
            revert UnderMinRedeemOrder(tokens, minTokens);
        }
        uint256 feePpm = router.redeemOrderFeePpm();
        (uint256 assets,) = _orderValue(router, tokens, feePpm);
        _checkMinWithdraw(assets);

        $._totalPendingOrderSize += tokens;
        uint256 orderId = $._orderCount;
        // slither-disable-next-line pess-dubious-typecast
        $._orders[orderId] = Order({
            assets: 0,
            tokens: tokens,
            owner: owner,
            receiver: receiver,
            controller: msg.sender,
            dueTime: SafeCast.toUint40(block.timestamp + $._fillWindow),
            status: OrderStatus.Pending,
            feePpm: uint24(feePpm)
        });
        $._orderCount++;

        if (msg.sender != owner) {
            router.__routerSpendAllowance(owner, msg.sender, tokens);
        }
        router.__routerTransfer(owner, address(this), tokens);

        emit CreatedRedeemOrder(msg.sender, receiver, owner, orderId, tokens);
        return orderId;
    }

    function createRedeemOrderWithMaxFee(uint256 tokens, address receiver, address owner, uint256 maxFeePpm)
        external
        returns (uint256)
    {
        uint256 feePpm = IYuzuUSDV3Router(address(this)).redeemOrderFeePpm();
        if (feePpm > maxFeePpm) {
            revert FeeOverMaxFee(feePpm, maxFeePpm);
        }
        return createRedeemOrder(tokens, receiver, owner);
    }

    function fillRedeemOrder(uint256 orderId) external {
        _checkRole(ORDER_FILLER_ROLE);
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
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

    function finalizeRedeemOrder(uint256 orderId) external {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        Order storage order = $._orders[orderId];
        if (msg.sender != order.owner && msg.sender != order.controller) {
            revert UnauthorizedOrderFinalizer(msg.sender, order.owner, order.controller);
        }
        if (order.status != OrderStatus.Filled) {
            revert OrderNotFilled(orderId);
        }
        if (router.paused()) {
            revert PausableUpgradeable.EnforcedPause();
        }

        order.status = OrderStatus.Finalized;
        $._totalUnfinalizedOrderValue -= order.assets;

        SafeERC20.safeTransfer(IERC20(router.asset()), order.receiver, order.assets);

        // slither-disable-next-line reentrancy-events
        emit FinalizedRedeemOrder(msg.sender, order.receiver, order.owner, orderId, order.assets, order.tokens);
        // slither-disable-next-line reentrancy-events
        emit Withdraw(msg.sender, order.receiver, order.owner, order.assets, order.tokens);
    }

    /// @dev Order fillers may force-cancel any pending order, even while paused and before it is due.
    function cancelRedeemOrder(uint256 orderId) external {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        Order storage order = $._orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (!IAccessControl(address(this)).hasRole(ORDER_FILLER_ROLE, msg.sender)) {
            if (router.paused()) {
                revert PausableUpgradeable.EnforcedPause();
            }
            if (msg.sender != order.owner && msg.sender != order.controller) {
                revert UnauthorizedOrderManager(msg.sender, order.owner, order.controller);
            }
            if (block.timestamp < order.dueTime) {
                revert OrderNotDue(orderId);
            }
        }

        order.status = OrderStatus.Cancelled;
        $._totalPendingOrderSize -= order.tokens;
        router.__routerTransfer(address(this), order.owner, order.tokens);

        // slither-disable-next-line reentrancy-events
        emit CancelledRedeemOrder(msg.sender, orderId);
    }

    function rescueTokens(address token, address to, uint256 amount) external {
        _checkRole(ADMIN_ROLE);
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        if (token == address(this)) {
            uint256 outstandingBalance =
                router.balanceOf(address(this)) - _getYuzuOrderBookStorage()._totalPendingOrderSize;
            if (amount > outstandingBalance) {
                revert ExceededOutstandingBalance(amount, outstandingBalance);
            }
        } else if (token == router.asset()) {
            revert InvalidAssetRescue(token);
        }
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function withdrawCollateral(uint256 assets, address receiver) external {
        _checkRole(ADMIN_ROLE);
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        uint256 liquidityBuffer = router.liquidityBufferSize();
        if (assets == type(uint256).max) {
            assets = liquidityBuffer;
        } else if (assets > liquidityBuffer) {
            revert ExceededLiquidityBuffer(assets, liquidityBuffer);
        }
        SafeERC20.safeTransfer(IERC20(router.asset()), receiver, assets);
        emit WithdrawnCollateral(receiver, assets);
    }

    function previewRedeemOrder(uint256 tokens) external view returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(msg.sender);
        (uint256 assets,) = _orderValue(router, tokens, router.redeemOrderFeePpm());
        return assets;
    }

    // slither-disable-next-line pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-event-setter
    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-event-setter
    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    // slither-disable-next-line pess-event-setter
    function setMinWithdraw(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minWithdraw;
        $._minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    // slither-disable-next-line pess-event-setter
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

    // slither-disable-next-line pess-event-setter
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

    // slither-disable-next-line pess-event-setter
    function setNavCooldown(uint256 newCooldown) external {
        _checkRole(ADMIN_ROLE);
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
        uint256 oldCooldown = $._cooldown;
        $._cooldown = newCooldown;
        emit UpdatedNavCooldown(oldCooldown, newCooldown);
    }

    function setTreasury(address newTreasury) external {
        _checkRole(ADMIN_ROLE);
        if (newTreasury == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldTreasury = IYuzuUSDV3Router(address(this)).treasury();
        _setPackedAddress(YUZU_PROTO_TREASURY_SLOT, newTreasury);
        emit UpdatedTreasury(oldTreasury, newTreasury);
    }

    function setFeeReceiver(address newFeeReceiver) external {
        _checkRole(ADMIN_ROLE);
        if (newFeeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldFeeReceiver = IYuzuUSDV3Router(address(this)).feeReceiver();
        _setPackedAddress(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, newFeeReceiver);
        emit UpdatedFeeReceiver(oldFeeReceiver, newFeeReceiver);
    }

    function setSupplyCap(uint256 newCap) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldCap = $._supplyCap;
        $._supplyCap = newCap;
        emit UpdatedSupplyCap(oldCap, newCap);
    }

    function setLiquidityBufferTargetSize(uint256 newSize) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldSize = $._liquidityBufferTargetSize;
        $._liquidityBufferTargetSize = newSize;
        emit UpdatedLiquidityBufferTargetSize(oldSize, newSize);
    }

    function setFillWindow(uint256 newWindow) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newWindow > 365 days) {
            revert FillWindowTooHigh(newWindow, 365 days);
        }
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldWindow = $._fillWindow;
        $._fillWindow = newWindow;
        emit UpdatedFillWindow(oldWindow, newWindow);
    }

    function setMinRedeemOrder(uint256 newMin) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldMin = $._minRedeemOrder;
        $._minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }

    // slither-disable-next-line pess-event-setter
    function setRedeemFee(uint256 newFeePpm) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemFeePpm();
        _setRedeemFeePpm(newFeePpm);
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    // slither-disable-next-line pess-event-setter
    function setRedeemOrderFee(uint256 newFeePpm) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemOrderFeePpm();
        _setRedeemOrderFeePpm(newFeePpm);
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    function setIsMintRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_MINT_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsMintRestricted(oldValue, restricted);
    }

    function setIsRedeemRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_REDEEM_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsRedeemRestricted(oldValue, restricted);
    }

    // Internal
    function _checkRole(bytes32 role) private view {
        if (!IAccessControl(address(this)).hasRole(role, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, role);
        }
    }

    /// @dev Values a redeem order: the tokens' worth at the current share price, minus the order fee.
    function _orderValue(IYuzuUSDV3Router router, uint256 tokens, uint256 feePpm)
        private
        view
        returns (uint256 assets, uint256 fee)
    {
        uint256 grossAssets = router.convertToAssets(tokens);
        fee = YuzuV3Fees.feeOnTotal(grossAssets, feePpm);
        assets = grossAssets - fee;
    }

    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minWithdraw;
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    // Storage
    function _setPackedAddress(uint256 slot, address value) private {
        uint256 mask = type(uint160).max;
        assembly {
            let oldValue := sload(slot)
            sstore(slot, or(and(oldValue, not(mask)), and(value, mask)))
        }
    }

    function _setPackedBool(uint256 slot, uint256 shift, bool value) private returns (bool oldValue) {
        uint256 mask = 0xff << shift;
        uint256 oldSlot;
        assembly {
            oldSlot := sload(slot)
        }
        oldValue = ((oldSlot >> shift) & 0xff) != 0;
        uint256 newSlot = oldSlot & ~mask;
        if (value) {
            newSlot |= 1 << shift;
        }
        assembly {
            sstore(slot, newSlot)
        }
    }

    function _redeemFeePpm() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_FEE_SLOT)
        }
    }

    function _setRedeemFeePpm(uint256 value) private {
        assembly {
            sstore(YUZU_PROTO_REDEEM_FEE_SLOT, value)
        }
    }

    function _redeemOrderFeePpm() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT)
        }
    }

    function _setRedeemOrderFeePpm(uint256 value) private {
        assembly {
            sstore(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT, value)
        }
    }

    function _getYuzuIssuerStorage() private pure returns (YuzuIssuerStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _getYuzuOrderBookStorage() private pure returns (YuzuOrderBookStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }
}
