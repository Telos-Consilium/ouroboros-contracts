// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Order} from "./IYuzuOrderBookDefinitions.sol";
import {IYuzu} from "./IYuzu.sol";

interface IYuzuOrderBook is IYuzu {
    function previewRedeemOrder(uint256 tokens) external view returns (uint256 assets);

    function maxRedeemOrder(address owner) external view returns (uint256);

    function createRedeemOrder(uint256 tokens, address receiver, address owner)
        external
        returns (uint256 orderId, uint256 assets);
    function fillRedeemOrder(uint256 orderId) external;
    function cancelRedeemOrder(uint256 orderId) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);

    function fillWindow() external view returns (uint256);
    function totalPendingOrderSize() external view returns (uint256);
    function totalUnfinalizedOrderValue() external view returns (uint256);
    function orderCount() external view returns (uint256);
}
