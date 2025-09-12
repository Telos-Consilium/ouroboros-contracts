// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzu} from "./IYuzu.sol";

interface IYuzuIssuer is IYuzu {
    function totalAssets() external view returns (uint256 assets);

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

    function deposit(uint256 assets, address receiver) external returns (uint256 tokens);
    function mint(uint256 tokens, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 tokens);
    function withdrawWithSlippage(uint256 assets, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 tokens);
    function redeem(uint256 tokens, address receiver, address owner) external returns (uint256 assets);
    function redeemWithSlippage(uint256 tokens, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256 assets);

    function withdrawCollateral(uint256 assets, address receiver) external;

    function treasury() external view returns (address);
    function cap() external view returns (uint256);
}
