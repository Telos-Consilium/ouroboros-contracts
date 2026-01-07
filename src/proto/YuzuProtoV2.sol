// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Order, OrderStatus} from "./YuzuOrderBook.sol";
import {YuzuProto} from "./YuzuProto.sol";

abstract contract YuzuProtoV2 is YuzuProto {
    function cancelRedeemOrder(uint256 orderId) public virtual override {
        address caller = _msgSender();
        Order storage order = _getOrder(orderId);
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (!hasRole(ORDER_FILLER_ROLE, caller)) {
            if (caller != order.owner && caller != order.controller) {
                revert UnauthorizedOrderManager(caller, order.owner, order.controller);
            }
            if (block.timestamp < order.dueTime) {
                revert OrderNotDue(orderId);
            }
        }

        _cancelRedeemOrder(order);

        emit CancelledRedeemOrder(caller, orderId);
    }
}
