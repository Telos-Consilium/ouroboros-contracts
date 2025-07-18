// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuUSDMinterDefinitions {
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event RedeemFeeRecipientUpdated(address oldRecipient, address newRecipient);
    event InstantRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event FastRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event StandardRedeemFeeBpsUpdated(uint256 oldFee, uint256 newFee);
    event FastFillWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event StandardFillWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event MaxMintPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event MaxRedeemPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event CollateralWithdrawn(uint256 amount, address to);
    event Minted(address from, address to, uint256 amount);
    event Redeemed(address from, address to, uint256 amount);
    event InstantRedeem(
        address from,
        address to,
        uint256 amount,
        uint256 feeBps
    );
    event FastRedeemOrderCreated(
        uint256 orderId,
        address owner,
        uint256 amount
    );
    event FastRedeemOrderFilled(
        uint256 orderId,
        address owner,
        address filler,
        address feeRecipient,
        uint256 amount,
        uint256 feeBps
    );
    event StandardRedeemOrderCreated(
        uint256 orderId,
        address owner,
        uint256 amount
    );
    event StandardRedeemOrderFilled(
        uint256 orderId,
        address owner,
        uint256 amount,
        uint256 feeBps
    );

    error InvalidZeroAddress();
    error InvalidToken();
    error InvalidAmount();
    error InvalidOrder();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error ExceedsLiquidityBuffer();
    error ExceedsOutstandingBalance();
    error OrderNotPending();
    error OrderNotDue();
}
