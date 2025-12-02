// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IRedeemFee {
    function redeemFeePpm() external view returns (uint256);
    function setRedeemFee(uint256 feePpm) external;
}

enum OrderStatus {
    Nil,
    Pending,
    Filled,
    Cancelled
}

struct Order {
    uint256 shares;
    address owner;
    address receiver;
    uint40 createdAt;
    OrderStatus status;
}

interface IPSMDefinitions {
    error InvalidZeroAddress();
    error VaultAssetMismatch(address expected, address underlying);
    error OrderNotPending(uint256 orderId);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event CreatedRedeemOrder(
        address indexed sender, address indexed receiver, address indexed owner, uint256 orderId, uint256 tokens
    );
    event FilledRedeemOrder(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 shares
    );
    event CancelledRedeemOrder(address sender, uint256 orderId);
    event DepositedLiquidity(address indexed sender, uint256 assets);
    event WithdrewLiquidity(address indexed receiver, uint256 assets);
}
