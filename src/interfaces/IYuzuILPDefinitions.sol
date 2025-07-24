// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuILPDefinitions {
    event RedeemOrderCreated(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);
    event RedeemFilled(
        uint256 indexed orderId, address indexed owner, address indexed filler, uint256 assets, uint256 shares
    );

    error InvalidAmount();
    error InvalidYield();
    error InvalidAddress();
    error InvalidToken();
    error InvalidOrder();
    error MaxDepositExceeded();
    error MaxMintExceeded();
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error MaxRedeemExceeded();
    error OrderAlreadyExecuted();
}
