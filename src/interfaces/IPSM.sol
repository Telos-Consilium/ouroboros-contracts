// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Order} from "./IPSMDefinitions.sol";

interface IPSM {
    function initialize(IERC20 __asset, IERC4626 __vault0, IERC4626 __vault1, address _admin) external;

    function asset() external view returns (address);
    function vault0() external view returns (address);
    function vault1() external view returns (address);

    function orderCount() external view returns (uint256);
    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function pendingOrderCount() external view returns (uint256);
    function getPendingOrderIds(uint256 offset, uint256 limit) external view returns (uint256[] memory);

    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver) external returns (uint256);
    function redeemWithSlippage(uint256 shares, address receiver, uint256 minAssets) external returns (uint256);
    function createRedeemOrder(uint256 shares, address receiver) external returns (uint256);
    function fillRedeemOrders(uint256 assets, uint256[] calldata orderIds) external;
    function cancelRedeemOrders(uint256[] calldata orderIds) external;
    function depositLiquidity(uint256 assets) external;
    function withdrawLiquidity(uint256 assets, address receiver) external;
}
