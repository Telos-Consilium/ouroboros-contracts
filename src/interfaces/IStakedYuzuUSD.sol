// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IStakedYuzuUSDDefinitions, Order} from "./IStakedYuzuUSDDefinitions.sol";

interface IStakedYuzuUSD is IERC4626 {
    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external;
    function setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock) external;
    function setRedeemDelay(uint256 newRedeemDelay) external;
    function rescueTokens(address token, address receiver, uint256 amount) external;

    function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256);
    function finalizeRedeem(uint256 orderId) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function orderCount() external view returns (uint256);
    function currentPendingOrderValue() external view returns (uint256);
    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function withdrawnPerBlock(uint256 blockNumber) external view returns (uint256);
    function maxDepositPerBlock() external view returns (uint256);
    function maxWithdrawPerBlock() external view returns (uint256);
    function redeemDelay() external view returns (uint256);
}
