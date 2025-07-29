// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    uint40 dueTime;
    bool executed;
}

interface IStakedYuzuUSDDefinitions {
    event RedeemInitiated(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);
    event RedeemFinalized(
        address indexed caller, uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares
    );
    event MaxDepositPerBlockUpdated(uint256 oldLimit, uint256 newLimit);
    event MaxWithdrawPerBlockUpdated(uint256 oldLimit, uint256 newLimit);
    event RedeemWindowUpdated(uint256 oldWindow, uint256 newWindow);

    error InvalidZeroShares();
    error InvalidZeroAmount();
    error InvalidToken(address token);
    error InvalidOrder(uint256 orderId);
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error MaxRedeemExceeded(uint256 requested, uint256 maxAllowed);
    error OrderAlreadyExecuted(uint256 orderId);
    error OrderNotDue(uint256 orderId);
}
