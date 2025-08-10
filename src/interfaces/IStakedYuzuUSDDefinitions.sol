// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

enum OrderStatus {
    Nil,
    Pending,
    Executed
}

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    address receiver;
    uint40 dueTime;
    OrderStatus status;
}

interface IStakedYuzuUSDDefinitions {
    event InitiatedRedeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 shares
    );
    event FinalizedRedeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 shares
    );
    event UpdatedMaxDepositPerBlock(uint256 oldLimit, uint256 newLimit);
    event UpdatedMaxWithdrawPerBlock(uint256 oldLimit, uint256 newLimit);
    event UpdatedRedeemDelay(uint256 oldDelay, uint256 newDelay);
    event UpdatedRedeemOrderFee(uint256 oldFee, uint256 newFee);

    // error InvalidZeroShares();
    // error InvalidZeroAmount();
    error InvalidZeroAddress();
    error InvalidRedeemOrderFee(uint256 provided);
    error InvalidAssetRescue(address token);
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error OrderNotPending(uint256 orderId);
    error OrderNotDue(uint256 orderId);
}
