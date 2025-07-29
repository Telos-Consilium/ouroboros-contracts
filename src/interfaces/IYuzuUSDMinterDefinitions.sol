// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

enum OrderStatus {
    Pending,
    Filled,
    Cancelled
}

struct Order {
    uint256 amount;
    address owner;
    uint32 feePpm;
    uint40 dueTime;
    OrderStatus status;
}

interface IYuzuUSDMinterDefinitions {
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event RedeemFeeRecipientUpdated(address oldRecipient, address newRecipient);
    event InstantRedeemFeePpmUpdated(uint256 oldFee, uint256 newFee);
    event FastRedeemFeePpmUpdated(uint256 oldFee, uint256 newFee);
    event StandardRedeemFeePpmUpdated(uint256 oldFee, uint256 newFee);
    event FastFillWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event StandardRedeemDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event MaxMintPerBlockUpdated(uint256 oldLimit, uint256 newLimit);
    event MaxRedeemPerBlockUpdated(uint256 oldLimit, uint256 newLimit);
    event CollateralWithdrawn(address indexed to, uint256 amount);
    event Minted(address indexed from, address indexed to, uint256 amount);
    event Redeemed(address indexed from, address indexed to, uint256 amount);
    event InstantRedeem(address indexed from, address indexed to, uint256 amount, uint256 fee);
    event FastRedeemOrderCreated(uint256 indexed orderId, address indexed owner, uint256 amount);
    event FastRedeemOrderFilled(
        uint256 indexed orderId,
        address indexed owner,
        address indexed filler,
        address feeRecipient,
        uint256 amount,
        uint256 fee
    );
    event FastRedeemOrderCancelled(uint256 indexed orderId);
    event StandardRedeemOrderCreated(uint256 indexed orderId, address indexed owner, uint256 amount);
    event StandardRedeemOrderFilled(address indexed caller, uint256 indexed orderId, address indexed owner, uint256 amount, uint256 fee);

    error InvalidZeroAddress();
    error InvalidZeroAmount();
    error InvalidToken(address token);
    error InvalidOrder(uint256 orderId);
    error InvalidFeePpm(uint256 provided);
    error Unauthorized();
    error MaxMintPerBlockExceeded(uint256 requested, uint256 maxAllowed);
    error MaxRedeemPerBlockExceeded(uint256 requested, uint256 maxAllowed);
    error LiquidityBufferExceeded(uint256 requested, uint256 available);
    error OutstandingBalanceExceeded(uint256 requested, uint256 available);
    error OrderNotPending(uint256 orderId);
    error OrderNotDue(uint256 orderId);
}
