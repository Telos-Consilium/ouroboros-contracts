// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import "./IYuzuUSD.sol";

enum OrderStatus {
    Pending,
    Filled,
    Cancelled
}

struct Order {
    uint256 amount;
    address owner;
    uint16 feeBps;
    uint40 dueTime;
    OrderStatus status;
}

interface IYuzuUSDMinter is IAccessControlDefaultAdminRules {
    // Admin functions
    function setTreasury(address newTreasury) external;
    function setRedeemFeeRecipient(address newRecipient) external;
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external;
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external;
    function setInstantRedeemFeeBps(uint256 newFeeBps) external;
    function setFastRedeemFeeBps(uint256 newFeeBps) external;
    function setStandardRedeemFeeBps(uint256 newFeeBps) external;
    function setFastFillWindow(uint256 newWindow) external;
    function setStandardFillWindow(uint256 newWindow) external;

    // Core functions
    function mint(address to, uint256 amount) external;
    function instantRedeem(address to, uint256 amount) external;
    function fastRedeem(uint256 amount) external;
    function fillFastRedeemOrder(
        uint256 orderId,
        address feeRecipient
    ) external;
    function standardRedeem(uint256 amount) external;
    function fillStandardRedeemOrder(uint256 orderId) external;
    function withdrawCollateral(uint256 amount, address to) external;

    // Emergency functions
    function rescueTokens(address token, uint256 amount, address to) external;
    function rescueOutstandingYuzuUSD(uint256 amount, address to) external;

    // Getter functions for public variables
    function yzusd() external view returns (IYuzuUSD);
    function collateralToken() external view returns (address);
    function treasury() external view returns (address);
    function redeemFeeRecipient() external view returns (address);
    function mintedPerBlock(
        uint256 blockNumber
    ) external view returns (uint256);
    function redeemedPerBlock(
        uint256 blockNumber
    ) external view returns (uint256);
    function maxMintPerBlock() external view returns (uint256);
    function maxRedeemPerBlock() external view returns (uint256);
    function getFastRedeemOrder(
        uint256 orderId
    ) external view returns (Order memory);
    function getStandardRedeemOrder(
        uint256 orderId
    ) external view returns (Order memory);
    function fastRedeemOrderCount() external view returns (uint256);
    function standardRedeemOrderCount() external view returns (uint256);
    function instantRedeemFeeBps() external view returns (uint256);
    function fastRedeemFeeBps() external view returns (uint256);
    function standardRedeemFeeBps() external view returns (uint256);
    function fastFillWindow() external view returns (uint256);
    function standardFillWindow() external view returns (uint256);
    function currentPendingFastRedeemValue() external view returns (uint256);
    function currentPendingStandardRedeemValue()
        external
        view
        returns (uint256);
}
