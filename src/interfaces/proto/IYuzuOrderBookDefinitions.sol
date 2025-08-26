// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuDefinitions} from "./IYuzuDefinitions.sol";

enum OrderStatus {
    Nil,
    Pending,
    Filled,
    Finalized,
    Cancelled
}

struct Order {
    uint256 assets;
    uint256 tokens;
    address owner;
    address receiver;
    address controller;
    uint40 dueTime;
    OrderStatus status;
}

interface IYuzuOrderBookDefinitions is IYuzuDefinitions {
    error InvalidZeroAddress();
    error FillWindowTooHigh(uint256 provided, uint256 max);
    error UnauthorizedOrderManager(address account, address owner, address controller);
    error UnauthorizedOrderFinalizer(address account, address receiver, address controller);
    error OrderNotPending(uint256 orderId);
    error OrderNotFilled(uint256 orderId);
    error OrderNotDue(uint256 orderId);
    error ExceededMaxRedeemOrder(address owner, uint256 token, uint256 max);

    event UpdatedFillWindow(uint256 oldWindow, uint256 newWindow);
    event CreatedRedeemOrder(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 tokens
    );
    event FilledRedeemOrder(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 tokens
    );
    event FinalizedRedeemOrder(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 tokens
    );
    event CancelledRedeemOrder(address sender, uint256 orderId);
}
