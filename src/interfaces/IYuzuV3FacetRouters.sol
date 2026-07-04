// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Throttle} from "./proto/IYuzuThrottleDefinitions.sol";

/// @dev The vault surface every facet consumes: pricing and order reads plus the ERC20 self-call
/// primitives. Vault-specific router interfaces extend this with their own needs.
interface IYuzuV3RouterBase {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function redeemOrderFeePpm() external view returns (uint256);
    function maxRedeemOrder(address owner) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function paused() external view returns (bool);
    function liquidityBufferSize() external view returns (uint256);
    function asset() external view returns (address);
    function treasury() external view returns (address);
    function feeReceiver() external view returns (address);
    function __routerBurn(address owner, uint256 tokens) external;
    function __routerTransfer(address from, address to, uint256 value) external;
    function __routerSpendAllowance(address owner, address spender, uint256 value) external;
}

interface IYuzuUSDV3Router is IYuzuV3RouterBase {}

interface IYuzuILPV3Router is IYuzuV3RouterBase {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 tokens) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function cap() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalAssetsWithRounding(uint256 rounding) external view returns (uint256);
    function decimals() external view returns (uint8);
    function poolSize() external view returns (uint256);
    function dailyLinearYieldRatePpm() external view returns (uint256);
    function lastPoolUpdateTimestamp() external view returns (uint256);
    function lastDistributedAmount() external view returns (uint256);
    function lastDistributionPeriod() external view returns (uint256);
    function lastDistributionTimestamp() external view returns (uint256);
    function netDistributedSinceUpdate() external view returns (uint256);
    function isMintRestricted() external view returns (bool);
    function isUpdatingPool() external view returns (bool);
    function mintFeePpm() external view returns (uint256);
    function managementFeeRatePpm() external view returns (uint256);
    function performanceFeeRatePpm() external view returns (uint256);
    function highWaterMark() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function getMintThrottle() external view returns (Throttle memory);
    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external;
}
