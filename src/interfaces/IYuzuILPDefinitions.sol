// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuILPDefinitions {
    event RedeemOrderCreated(uint256 indexed orderId, address indexed owner, uint256 assets, uint256 shares);
    event RedeemOrderFilled(
        uint256 indexed orderId, address indexed owner, address indexed filler, uint256 assets, uint256 shares
    );

    error InvalidZeroAddress();
    error InvalidZeroShares();
    error InvalidZeroAmount();
    error InvalidYield(uint256 provided);
    error InvalidToken(address token);
    error InvalidOrder(uint256 orderId);
    error InvalidPoolSize(uint256 provided);
    error WithdrawalAllowanceExceedsPoolSize(uint256 provided);
    error MaxDepositExceeded(uint256 requested, uint256 maxAllowed);
    error MaxMintExceeded(uint256 requested, uint256 maxAllowed);
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error MaxRedeemExceeded(uint256 requested, uint256 maxAllowed);
    error OrderAlreadyExecuted();
}
