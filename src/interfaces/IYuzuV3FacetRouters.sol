// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Throttle} from "./proto/IYuzuThrottleDefinitions.sol";

interface IYuzuUSDV3Router {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 tokens) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 tokens) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function redeemFeePpm() external view returns (uint256);
    function cap() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function paused() external view returns (bool);
    function isMintRestricted() external view returns (bool);
    function isRedeemRestricted() external view returns (bool);
    function liquidityBufferSize() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function minWithdraw() external view returns (uint256);
    function nav() external view returns (uint256);
    function getMintThrottle() external view returns (Throttle memory);
    function getRedeemThrottle() external view returns (Throttle memory);
    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external;
    function __routerWithdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 tokens,
        uint256 fee
    ) external;
}

interface IYuzuILPV3Router {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 tokens) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function cap() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalAssetsWithRounding(uint256 rounding) external view returns (uint256);
    function decimals() external view returns (uint8);
    function poolSize() external view returns (uint256);
    function dailyLinearYieldRatePpm() external view returns (uint256);
    function lastPoolUpdateTimestamp() external view returns (uint256);
    function netDistributedSinceUpdate() external view returns (uint256);
    function paused() external view returns (bool);
    function isMintRestricted() external view returns (bool);
    function isUpdatingPool() external view returns (bool);
    function liquidityBufferSize() external view returns (uint256);
    function mintFeePpm() external view returns (uint256);
    function managementFeeRatePpm() external view returns (uint256);
    function performanceFeeRatePpm() external view returns (uint256);
    function highWaterMark() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function getMintThrottle() external view returns (Throttle memory);
    function asset() external view returns (address);
    function treasury() external view returns (address);
    function feeReceiver() external view returns (address);
    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external;
    function __routerBurn(address owner, uint256 tokens) external;
}
