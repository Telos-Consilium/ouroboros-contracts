// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IYuzu} from "./IYuzu.sol";

interface IYuzuIssuer is IYuzu {
    function previewDeposit(uint256 assets) external view returns (uint256 tokens);
    function previewMint(uint256 tokens) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 tokens);
    function previewRedeem(uint256 tokens) external view returns (uint256 assets);

    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    function maxDeposit(address) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 tokens, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 tokens, address receiver, address owner) external returns (uint256);

    function withdrawCollateral(uint256 assets, address receiver) external;

    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function withdrawnPerBlock(uint256 blockNumber) external view returns (uint256);

    function treasury() external view returns (address);
    function maxDepositPerBlock() external view returns (uint256);
    function maxWithdrawPerBlock() external view returns (uint256);
}
