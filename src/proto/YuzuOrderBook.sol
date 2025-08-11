// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "../interfaces/proto/IYuzuOrderBookDefinitions.sol";

abstract contract YuzuOrderBook is ContextUpgradeable, IYuzuOrderBookDefinitions {
    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _totalPendingOrderSize;
        uint256 _orderCount;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation =
        0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    // slither-disable-next-line pess-unprotected-initialize
    function __YuzuOrderBook_init(uint256 _fillWindow) internal onlyInitializing {
        __YuzuOrderBook_init_unchained(_fillWindow);
    }

    // slither-disable-next-line pess-unprotected-initialize
    function __YuzuOrderBook_init_unchained(uint256 _fillWindow) internal onlyInitializing {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._fillWindow = _fillWindow;
    }

    /// @dev See {IERC4626}
    function asset() public view virtual returns (address);

    function previewRedeemOrder(uint256 tokens) public view virtual returns (uint256 assets);

    /// @dev See {IERC20}
    function __yuzu_balanceOf(address account) public view virtual returns (uint256);
    function __yuzu_burn(address account, uint256 amount) internal virtual;
    function __yuzu_transfer(address from, address to, uint256 value) internal virtual;

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount) internal virtual;

    function maxRedeemOrder(address owner) public view virtual returns (uint256) {
        return __yuzu_balanceOf(owner);
    }

    function createRedeemOrder(uint256 tokens, address receiver, address owner)
        public
        virtual
        returns (uint256, uint256)
    {
        uint256 maxTokens = maxRedeemOrder(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }

        uint256 assets = previewRedeemOrder(tokens);
        address caller = _msgSender();
        uint256 orderId = _createRedeemOrder(caller, receiver, owner, tokens, assets);

        emit CreatedRedeemOrder(caller, receiver, owner, orderId, assets, tokens);

        return (orderId, assets);
    }

    function fillRedeemOrder(uint256 orderId) public virtual {
        Order storage order = _getOrder(orderId);
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        address caller = _msgSender();

        _fillRedeemOrder(caller, order);

        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, order.assets, order.tokens);
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.tokens);
    }

    function cancelRedeemOrder(uint256 orderId) public virtual {
        Order storage order = _getOrder(orderId);
        if (_msgSender() != order.owner) {
            revert Unauthorized(_msgSender(), order.owner);
        }
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (block.timestamp < order.dueTime) {
            revert OrderNotDue(orderId);
        }

        _cancelRedeemOrder(order);

        emit CancelledRedeemOrder(orderId);
    }

    function fillWindow() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._fillWindow;
    }

    function totalPendingOrderSize() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._totalPendingOrderSize;
    }

    function orderCount() public view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orderCount;
    }

    function getRedeemOrder(uint256 orderId) public view returns (Order memory) {
        return _getOrder(orderId);
    }

    function _createRedeemOrder(address caller, address receiver, address owner, uint256 tokens, uint256 assets)
        internal
        virtual
        returns (uint256)
    {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize += tokens;

        uint256 orderId = $._orderCount;
        $._orders[orderId] = Order({
            assets: assets,
            tokens: tokens,
            owner: owner,
            receiver: receiver,
            dueTime: SafeCast.toUint40(block.timestamp + $._fillWindow),
            status: OrderStatus.Pending
        });
        $._orderCount++;

        if (caller != owner) {
            __yuzu_spendAllowance(owner, caller, tokens);
        }
        __yuzu_transfer(owner, address(this), tokens);

        return orderId;
    }

    function _fillRedeemOrder(address caller, Order storage order) internal virtual {
        order.status = OrderStatus.Filled;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;

        __yuzu_burn(address(this), order.tokens);
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, order.receiver, order.assets);
    }

    function _cancelRedeemOrder(Order storage order) internal virtual {
        order.status = OrderStatus.Cancelled;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;
        __yuzu_transfer(address(this), order.owner, order.tokens);
    }

    function _getYuzuOrderBookStorage() private pure returns (YuzuOrderBookStorage storage $) {
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }

    function _getOrder(uint256 orderId) private view returns (Order storage) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orders[orderId];
    }

    function _setFillWindow(uint256 newWindow) internal {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldWindow = $._fillWindow;
        $._fillWindow = newWindow;
        emit UpdatedFillWindow(oldWindow, newWindow);
    }
}
