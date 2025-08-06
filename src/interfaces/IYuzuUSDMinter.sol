// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./IYuzuUSD.sol";
import "./IYuzuUSDMinterDefinitions.sol";

interface IYuzuUSDMinter {
    // Admin functions
    function setTreasury(address newTreasury) external;
    function setRedeemFeeRecipient(address newRecipient) external;
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external;
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external;
    function setInstantRedeemFeePpm(uint256 newFeePpm) external;
    function setFastRedeemFeePpm(uint256 newFeePpm) external;
    function setFastFillWindow(uint256 newWindow) external;
    function rescueTokens(address token, address receiver, uint256 amount) external;
    function withdrawCollateral(uint256 collateralAmount, address receiver) external;

    // Core functions
    function previewDeposit(uint256 collateralAmount) external view returns (uint256);
    function previewMint(uint256 tokenAmount) external view returns (uint256);
    function previewInstantRedeem(uint256 tokenAmount) external view returns (uint256);
    function previewFastRedeem(uint256 tokenAmount) external view returns (uint256);
    function mint(uint256 tokenAmount, address receiver) external returns (uint256);
    function instantRedeem(uint256 tokenAmount, address receiver) external returns (uint256);
    function createFastRedeemOrder(uint256 tokenAmount) external returns (uint256);
    function fillFastRedeemOrder(uint256 orderId, address feeRecipient) external;
    function cancelFastRedeemOrder(uint256 orderId) external;

    // Getter functions for public variables
    function yzusd() external view returns (IYuzuUSD);
    function collateralToken() external view returns (address);
    function treasury() external view returns (address);
    function redeemFeeRecipient() external view returns (address);
    function mintedPerBlock(uint256 blockNumber) external view returns (uint256);
    function redeemedPerBlock(uint256 blockNumber) external view returns (uint256);
    function maxMintPerBlock() external view returns (uint256);
    function maxRedeemPerBlock() external view returns (uint256);
    function getFastRedeemOrder(uint256 orderId) external view returns (Order memory);
    function fastRedeemOrderCount() external view returns (uint256);
    function instantRedeemFeePpm() external view returns (uint256);
    function fastRedeemFeePpm() external view returns (uint256);
    function fastFillWindow() external view returns (uint256);
    function currentPendingFastRedeemValue() external view returns (uint256);
}
