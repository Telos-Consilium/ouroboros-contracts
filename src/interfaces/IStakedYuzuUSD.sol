// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Order} from "./IStakedYuzuUSDDefinitions.sol";

interface IStakedYuzuUSD is IERC4626 {
    function previewDeposit(uint256 assets) external view returns (uint256 tokens);
    function previewMint(uint256 tokens) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 tokens);
    function previewRedeem(uint256 tokens) external view returns (uint256 assets);

    function maxDeposit(address) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256);
    function finalizeRedeem(uint256 orderId) external;

    function setMaxDepositPerBlock(uint256 newMax) external;
    function setMaxWithdrawPerBlock(uint256 newMax) external;
    function setRedeemDelay(uint256 newDelay) external;
    function setRedeemFee(uint256 newFee) external;
    function rescueTokens(address token, address receiver, uint256 amount) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function orderCount() external view returns (uint256);
    function totalPendingOrderValue() external view returns (uint256);
    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function withdrawnPerBlock(uint256 blockNumber) external view returns (uint256);
    function maxDepositPerBlock() external view returns (uint256);
    function maxWithdrawPerBlock() external view returns (uint256);
    function redeemDelay() external view returns (uint256);
}
