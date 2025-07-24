// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    bool executed;
}

interface IYuzuILP is IERC4626, IAccessControlDefaultAdminRules {
    function setTreasury(address newTreasury) external;
    function updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm)
        external;
    function setMaxDepositPerBlock(uint256 newMax) external;
    function createRedeemOrder(uint256 assets) external returns (uint256 orderId);
    function executeRedeemOrder(uint256 orderId) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);

    function treasury() external view returns (address);
    function poolSize() external view returns (uint256);
    function withdrawAllowance() external view returns (uint256);
    function dailyLinearYieldRatePpm() external view returns (uint256);
    function lastPoolUpdateTimestamp() external view returns (uint256);
    function maxDepositPerBlock() external view returns (uint256);
    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function redeemOrderCount() external view returns (uint256);
}
