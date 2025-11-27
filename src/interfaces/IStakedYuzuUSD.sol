// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Order, IntegrationConfig} from "./IStakedYuzuUSDDefinitions.sol";

interface IStakedYuzuUSD is IERC4626 {
    function initialize(
        IERC20 _asset,
        string memory __name,
        string memory __symbol,
        address _owner,
        address _feeReceiver,
        uint256 _redeemDelay
    ) external;

    function maxRedeemOrder(address owner) external view returns (uint256);

    function initiateRedeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 orderId, uint256 assets);
    function initiateRedeemWithSlippage(uint256 shares, address receiver, address _owner, uint256 minAssets)
        external
        returns (uint256 orderId, uint256 assets);
    function finalizeRedeem(uint256 orderId) external;

    function distribute(uint256 assets, uint256 period) external;
    function terminateDistribution(address receiver) external;
    function rescueTokens(address token, address receiver, uint256 amount) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function orderCount() external view returns (uint256);
    function feeReceiver() external view returns (address);
    function redeemDelay() external view returns (uint256);
    function redeemFeePpm() external view returns (uint256);
    function lastDistributedAmount() external view returns (uint256);
    function lastDistributionPeriod() external view returns (uint256);
    function lastDistributionTime() external view returns (uint256);
    function totalPendingOrderValue() external view returns (uint256);

    function setFeeReceiver(address newFeeReceiver) external;
    function setRedeemDelay(uint256 newDelay) external;
    function setRedeemFee(uint256 newFeePpm) external;

    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

interface IStakedYuzuUSDV2 is IStakedYuzuUSD {
    function getIntegration(address integration) external view returns (IntegrationConfig memory);
    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee) external;
}
