// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IYuzuProtoDefinitions {
    error FeeTooHigh(uint256 provided, uint256 max);
    error InvalidAssetRescue(address token);
    error ExceededOutstandingBalance(uint256 requested, uint256 outstandingBalance);

    event UpdatedRedeemFee(uint256 oldFee, uint256 newFee);
    event UpdatedRedeemOrderFee(int256 oldFee, int256 newFee);
    event UpdatedTreasury(address oldTreasury, address newTreasury);
}
