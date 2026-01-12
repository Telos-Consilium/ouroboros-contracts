// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Order, OrderStatus} from "./YuzuOrderBook.sol";
import {YuzuProto} from "./YuzuProto.sol";

abstract contract YuzuProtoV2 is YuzuProto {
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function __YuzuProtoV2_init(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        address _feeReceiver,
        uint256 _supplyCap,
        uint256 _fillWindow,
        uint256 _minRedeemOrder
    ) internal onlyInitializing {
        __YuzuProto_init(
            __asset, __name, __symbol, _admin, __treasury, _feeReceiver, _supplyCap, _fillWindow, _minRedeemOrder
        );
        __YuzuProtoV2_init_unchained();
    }

    function __YuzuProtoV2_init_unchained() internal onlyInitializing {
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
    }

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

    function burn(uint256 amount) public virtual onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), amount);
    }
}
