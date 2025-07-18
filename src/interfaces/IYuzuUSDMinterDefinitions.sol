// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuUSDMinterDefinitions {
    event TreasuryUpdated(
        address oldTreasury,
        address newTreasury
    );
    event RedeemFeeRecipientUpdated(
        address oldRecipient,
        address newRecipient
    );
    event InstantRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event FastRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event StandardRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event FastFillWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event StandardFillWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event MaxMintPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event MaxRedeemPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event CollateralWithdrawn(address indexed to, uint256 amount);
    event Minted(address indexed from, address indexed to, uint256 amount);
    event Redeemed(address indexed from, address indexed to, uint256 amount);
    event InstantRedeem(
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 feeBps
    );
    event FastRedeemOrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amount
    );
    event FastRedeemOrderFilled(
        uint256 indexed orderId,
        address indexed owner,
        address indexed filler,
        address feeRecipient,
        uint256 amount,
        uint256 feeBps
    );
    event FastRedeemOrderCancelled(uint256 indexed orderId);
    event StandardRedeemOrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amount
    );
    event StandardRedeemOrderFilled(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amount,
        uint256 feeBps
    );

    error InvalidZeroAddress();
    error InvalidToken();
    error InvalidAmount();
    error InvalidOrder();
    error InvalidFeeBps();
    error Unauthorized();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error ExceedsLiquidityBuffer();
    error ExceedsOutstandingBalance();
    error OrderNotPending();
    error OrderNotDue();
}
