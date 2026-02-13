// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "../interfaces/proto/IYuzuOrderBookDefinitions.sol";

abstract contract YuzuOrderBook is ContextUpgradeable, IYuzuOrderBookDefinitions {
    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _totalPendingOrderSize;
        uint256 _totalUnfinalizedOrderValue;
        uint256 _orderCount;
        uint256 _minRedeemOrder;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation =
        0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    function __YuzuOrderBook_init(uint256 _fillWindow, uint256 _minRedeemOrder) internal onlyInitializing {
        __YuzuOrderBook_init_unchained(_fillWindow, _minRedeemOrder);
    }

    function __YuzuOrderBook_init_unchained(uint256 _fillWindow, uint256 _minRedeemOrder) internal onlyInitializing {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._fillWindow = _fillWindow;
        $._minRedeemOrder = _minRedeemOrder;
    }

    /// @dev See {IERC4626}
    function asset() public view virtual returns (address);

    /// @dev See {IERC20}
    function __yuzu_balanceOf(address account) internal view virtual returns (uint256);
    function __yuzu_burn(address account, uint256 amount) internal virtual;
    function __yuzu_transfer(address from, address to, uint256 value) internal virtual;

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function _previewRedeemOrder(uint256 tokens, uint256 feePpm) internal view virtual returns (uint256, uint256);

    /// @notice Returns the maximum amount of tokens that can be redeemed by an owner in a single order
    function maxRedeemOrder(address owner) public view virtual returns (uint256) {
        return __yuzu_balanceOf(owner);
    }

    /// @notice Preview the amount of assets to receive when redeeming tokens with an order
    function previewRedeemOrder(uint256 tokens) public view virtual returns (uint256) {
        (uint256 assets,) = _previewRedeemOrder(tokens, 0);
        return assets;
    }

    /// @notice Create a redeem order
    function createRedeemOrder(uint256 tokens, address receiver, address owner) public virtual returns (uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxTokens = maxRedeemOrder(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }
        uint256 minTokens = minRedeemOrder();
        if (tokens < minTokens) {
            revert UnderMinRedeemOrder(tokens, minTokens);
        }

        address caller = _msgSender();
        uint256 orderId = _createRedeemOrder(caller, receiver, owner, tokens);

        emit CreatedRedeemOrder(caller, receiver, owner, orderId, tokens);

        return (orderId);
    }

    /// @notice Fill a redeem order
    function fillRedeemOrder(uint256 orderId) public virtual {
        Order storage order = _getOrder(orderId);
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        (uint256 assets, uint256 fee) = _previewRedeemOrder(order.tokens, uint256(order.feePpm));
        address caller = _msgSender();
        _fillRedeemOrder(caller, order, assets, fee);

        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, assets, order.tokens, fee);
    }

    /// @notice Finalize a redeem order
    function finalizeRedeemOrder(uint256 orderId) public virtual {
        address caller = _msgSender();
        Order storage order = _getOrder(orderId);
        if (caller != order.owner && caller != order.controller) {
            revert UnauthorizedOrderFinalizer(caller, order.owner, order.controller);
        }
        if (order.status != OrderStatus.Filled) {
            revert OrderNotFilled(orderId);
        }

        _finalizeRedeemOrder(order);

        emit FinalizedRedeemOrder(caller, order.receiver, order.owner, orderId, order.assets, order.tokens);
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.tokens);
    }

    /// @notice Cancel a redeem order
    function cancelRedeemOrder(uint256 orderId) public virtual {
        address caller = _msgSender();
        Order storage order = _getOrder(orderId);
        if (caller != order.owner && caller != order.controller) {
            revert UnauthorizedOrderManager(caller, order.owner, order.controller);
        }
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (block.timestamp < order.dueTime) {
            revert OrderNotDue(orderId);
        }

        _cancelRedeemOrder(order);

        emit CancelledRedeemOrder(caller, orderId);
    }

    function fillWindow() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._fillWindow;
    }

    function minRedeemOrder() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._minRedeemOrder;
    }

    function totalPendingOrderSize() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._totalPendingOrderSize;
    }

    function totalUnfinalizedOrderValue() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._totalUnfinalizedOrderValue;
    }

    function orderCount() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orderCount;
    }

    function getRedeemOrder(uint256 orderId) public view returns (Order memory) {
        return _getOrder(orderId);
    }

    function _createRedeemOrder(address caller, address receiver, address owner, uint256 tokens)
        internal
        virtual
        returns (uint256)
    {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize += tokens;

        uint256 orderId = $._orderCount;
        $._orders[orderId] = _newRedeemOrder(caller, receiver, owner, tokens);
        $._orderCount++;

        if (caller != owner) {
            __yuzu_spendAllowance(owner, caller, tokens);
        }
        __yuzu_transfer(owner, address(this), tokens);

        return orderId;
    }

    function _fillRedeemOrder(address caller, Order storage order, uint256 assets, uint256 fee) internal virtual {
        order.status = OrderStatus.Filled;
        order.assets = assets;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;
        $._totalUnfinalizedOrderValue += assets;

        __yuzu_burn(address(this), order.tokens);
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
    }

    function _finalizeRedeemOrder(Order storage order) internal virtual {
        order.status = OrderStatus.Finalized;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalUnfinalizedOrderValue -= order.assets;

        SafeERC20.safeTransfer(IERC20(asset()), order.receiver, order.assets);
    }

    function _cancelRedeemOrder(Order storage order) internal virtual {
        order.status = OrderStatus.Cancelled;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;
        __yuzu_transfer(address(this), order.owner, order.tokens);
    }

    function _newRedeemOrder(address caller, address receiver, address owner, uint256 tokens)
        internal
        view
        virtual
        returns (Order memory)
    {
        return Order({
            assets: 0,
            tokens: tokens,
            owner: owner,
            receiver: receiver,
            controller: caller,
            dueTime: SafeCast.toUint40(block.timestamp + _getYuzuOrderBookStorage()._fillWindow),
            status: OrderStatus.Pending,
            feePpm: 0
        });
    }

    function _getYuzuOrderBookStorage() private pure returns (YuzuOrderBookStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }

    function _getOrder(uint256 orderId) internal view returns (Order storage) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orders[orderId];
    }

    function _setFillWindow(uint256 newWindow) internal {
        if (newWindow > 365 days) {
            revert FillWindowTooHigh(newWindow, 365 days);
        }
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldWindow = $._fillWindow;
        $._fillWindow = newWindow;
        emit UpdatedFillWindow(oldWindow, newWindow);
    }

    function _setMinRedeemOrder(uint256 newMin) internal {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldMin = $._minRedeemOrder;
        $._minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }
}
