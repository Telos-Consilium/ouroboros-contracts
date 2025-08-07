// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

enum OrderStatus {
    Nil,
    Pending,
    Filled,
    Cancelled
}

struct Order {
    uint256 assets;
    uint256 tokens;
    address owner;
    uint40 dueTime;
    OrderStatus status;
}

abstract contract YuzuIssuer is ContextUpgradeable {
    error Unauthorized();
    error OrderNotPending(uint256 orderId);
    error OrderNotDue(uint256 orderId);

    event CreatedRedeemOrder(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 tokens);
    event FilledRedeemOrder(uint256 indexed orderId, address indexed owner, address indexed filler, uint256 assets, uint256 tokens);
    event CancelledRedeemOrder(uint256 indexed orderId);

    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _currentPendingOrderValue;
        uint256 _orderCount;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation = 0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    function asset() public view virtual returns (address);
    function previewRedeemOrder(uint256 tokens) public view virtual returns (uint256 assets);
    function validateOrderFiller(address account) internal view virtual;

    function __YuzuIssuer_token_transfer(address to, uint256 value) internal virtual;
    function __YuzuIssuer_token_transferFrom(address from, address to, uint256 value) internal virtual;
    function __YuzuIssuer_token_burn(uint256 value) internal virtual;

    /**
     * @notice Creates a  redemption order for {tokenAmount} of yzusd.
     *
     * Returns the order ID.
     * Emits a `CreatedRedeemOrder` event with the order ID, order owner, and amount.
     * Reverts if the amount is zero.
     */
    function createRedeemOrder(uint256 tokens) public returns (uint256)
    {
        uint256 assets = previewRedeemOrder(tokens);
        address owner = _msgSender();
        uint256 orderId = _createRedeemOrder(owner, assets, tokens);
        emit CreatedRedeemOrder(orderId, owner, assets, tokens);
        return orderId;
    }

    /**
     * @notice Fills a  redemption order with {orderId} by transferring the amount to the owner.
     *
     * The fee is transferred to {feeRecipient}.
     * Emits a `FilledRedeemOrder` event with the order ID, owner, filler, fee recipient, amount, and fee.
     * Emits a `Redeemed` event with the order owner, recipient, and amount.
     * Reverts if called by anyone but an order filler.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
     */
    function fillRedeemOrder(uint256 orderId)
        external
    {
        address filler = _msgSender();
        validateOrderFiller(filler);
        Order storage order = _getOrder(orderId);
        if (order.status != OrderStatus.Pending) revert OrderNotPending(orderId);
        _fillRedeemOrder(order, filler);
        emit FilledRedeemOrder(orderId, order.owner, filler, order.assets, order.tokens);
    }

    /**
     * @notice Cancels a  redemption order with {orderId}.
     *
     * Emits a `CancelledRedeemOrder` event with the order ID.
     * Reverts if called by anyone but the order owner.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
     * Reverts if the order is not yet due for cancellation.
     */
    function cancelRedeemOrder(uint256 orderId) external {
        Order storage order = _getOrder(orderId);
        if (_msgSender() != order.owner) revert Unauthorized();
        if (order.status != OrderStatus.Pending) revert OrderNotPending(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);
        _cancelRedeemOrder(order);
        emit CancelledRedeemOrder(orderId);
    }

    /**
     * @notice Returns a  redemption order by {orderId}.
     */
    function getRedeemOrder(uint256 orderId) public view returns (Order memory) {
        return _getOrder(orderId);
    }

    /**
     * @dev Internal function to create a  redemption order.
     *
     * Transfers yzusd from {owner} to the contract and creates a  redemption order.
     * Returns the order ID.
     */
    function _createRedeemOrder(address owner, uint256 tokens, uint256 assets) internal returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._currentPendingOrderValue += assets;
        uint256 orderId = $._orderCount;
        $._orders[orderId] = Order({
            assets: assets,
            tokens: tokens,
            owner: owner,
            dueTime: uint40(block.timestamp + $._fillWindow),
            status: OrderStatus.Pending
        });
        $._orderCount++;
        __YuzuIssuer_token_transferFrom(owner, address(this), tokens);
        return orderId;
    }

    /**
     * @dev Internal function to fill a  redemption order.
     *
     * Marks the order as filled, updates the current pending  redemption value,
     * and transfers the assets to the owner.
     * Transfers the fee to the fee recipient if applicable.
     */
    function _fillRedeemOrder(Order storage order, address filler) internal {
        order.status = OrderStatus.Filled;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._currentPendingOrderValue -= order.assets;
        __YuzuIssuer_token_burn(order.tokens);
        SafeERC20.safeTransferFrom(IERC20(asset()), filler, order.owner, order.assets);
    }

    /**
     * @dev Internal function to cancel a  redemption order.
     *
     * Marks the order as cancelled, updates the current pending  redemption value,
     * and transfers the yzusd back to the owner.
     */
    function _cancelRedeemOrder(Order storage order) internal {
        order.status = OrderStatus.Cancelled;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._currentPendingOrderValue -= order.assets;
        __YuzuIssuer_token_transfer(order.owner, order.tokens);
    }

    function _getYuzuOrderBookStorage() private pure returns (YuzuOrderBookStorage storage $) {
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }

    function _getOrderCount() private view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orderCount;
    }

    function _getOrder(uint256 orderId) private view returns (Order storage) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._orders[orderId];
    }

    function _getFillWindow() internal view returns (uint256) {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        return $._fillWindow;
    }

    function _setFillWindow(uint256 newWindow) internal {
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._fillWindow = newWindow;
    }
}
