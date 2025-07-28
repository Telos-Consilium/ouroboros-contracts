// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    uint40 dueTime;
    bool executed;
}

interface IStakedYuzuUSD is IERC4626 {
    // Ownership functions
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function renounceOwnership() external;

    // Admin functions
    function setMaxDepositPerBlock(uint256 newMax) external;
    function setMaxWithdrawPerBlock(uint256 newMax) external;
    function setRedeemWindow(uint256 newWindow) external;
    function rescueTokens(address token, address to, uint256 amount) external;

    // Core functions
    function initiateRedeem(uint256 shares) external returns (uint256, uint256);
    function finalizeRedeem(uint256 orderId) external;

    // View functions
    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function currentRedeemAssetCommitment() external view returns (uint256);
    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function withdrawnPerBlock(uint256 blockNumber) external view returns (uint256);
    function maxDepositPerBlock() external view returns (uint256);
    function maxWithdrawPerBlock() external view returns (uint256);
    function redeemOrderCount() external view returns (uint256);
    function redeemWindow() external view returns (uint256);
}
