// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20Burnable {
    function burn(uint256 value) external;
    function burnFrom(address account, uint256 value) external;
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
    error UnderMinRedeemOrder(uint256 shares, uint256 min);
    error OrderNotPending(uint256 orderId);
    error WithdrewLessThanMinAssets(uint256 assets, uint256 min);

    event UpdatedMinRedeemOrder(uint256 oldMin, uint256 newMin);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event CreatedRedeemOrder(
        address indexed sender, address indexed receiver, address indexed owner, uint256 orderId, uint256 shares
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
