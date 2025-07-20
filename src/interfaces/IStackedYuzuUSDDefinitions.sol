// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IStackedYuzuUSDDefinitions {
    event RedeemInitiated(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);
    event RedeemFinalized(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);

    error WithdrawNotSupported();
    error InvalidAmount();
    error RedeemNotSupported();
    error MaxRedeemExceeded();
    error InvalidOrder();
    error OrderAlreadyExecuted();
    error OrderNotDue();
}
