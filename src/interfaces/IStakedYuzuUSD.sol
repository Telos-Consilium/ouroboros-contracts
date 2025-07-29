// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./IStakedYuzuUSDDefinitions.sol";

interface IStakedYuzuUSD is IERC4626 {
    // Admin functions
    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external;
    function setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock) external;
    function setRedeemDelay(uint256 newRedeemDelay) external;
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
    function redeemDelay() external view returns (uint256);
}
