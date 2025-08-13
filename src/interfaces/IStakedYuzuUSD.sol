// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Order} from "./IStakedYuzuUSDDefinitions.sol";

interface IStakedYuzuUSD is IERC4626 {
    function initialize(
        IERC20 _asset,
        string memory name_,
        string memory symbol_,
        address _owner,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _redeemDelay
    ) external;

    function previewDeposit(uint256 assets) external view returns (uint256 tokens);
    function previewMint(uint256 tokens) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 tokens);
    function previewRedeem(uint256 tokens) external view returns (uint256 assets);

    function maxDeposit(address) external view returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256);
    function finalizeRedeem(uint256 orderId) external;

    function rescueTokens(address token, address receiver, uint256 amount) external;

    function getRedeemOrder(uint256 orderId) external view returns (Order memory);
    function orderCount() external view returns (uint256);
    function totalPendingOrderValue() external view returns (uint256);
    function depositedPerBlock(uint256 blockNumber) external view returns (uint256);
    function withdrawnPerBlock(uint256 blockNumber) external view returns (uint256);
    function maxDepositPerBlock() external view returns (uint256);
    function maxWithdrawPerBlock() external view returns (uint256);
    function redeemFeePpm() external view returns (uint256);
    function redeemDelay() external view returns (uint256);

    function setMaxDepositPerBlock(uint256 newMax) external;
    function setMaxWithdrawPerBlock(uint256 newMax) external;
    function setRedeemDelay(uint256 newDelay) external;
    function setRedeemFee(uint256 newFee) external;
}
