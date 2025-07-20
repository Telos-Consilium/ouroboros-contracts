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
    function owner() external returns (address);
    function pendingOwner() external returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function renounceOwnership() external;

    function setMaxMintPerBlockInAssets(uint256 newMax) external;
    function setMaxRedeemPerBlockInAssets(uint256 newMax) external;
    function setRedeemWindow(uint256 newWindow) external;
    function initiateRedeem(uint256 shares) external returns (uint256, uint256);
    function finalizeRedeem(uint256 orderId) external;
    function getRedeemOrder(uint256 orderId) external returns (Order memory);

    function currentRedeemAssetCommitment() external view returns (uint256);
    function mintedPerBlockInAssets(uint256 blockNumber) external view returns (uint256);
    function redeemedPerBlockInAssets(uint256 blockNumber) external view returns (uint256);
    function maxMintPerBlockInAssets() external view returns (uint256);
    function maxRedeemPerBlockInAssets() external view returns (uint256);
    function redeemOrderCount() external view returns (uint256);
    function redeemWindow() external view returns (uint256);
}
