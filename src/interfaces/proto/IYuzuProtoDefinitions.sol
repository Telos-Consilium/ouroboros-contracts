// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuProtoDefinitions {
    error InvalidZeroAddress();
    error InvalidRedeemFee(uint256 provided);
    error InvalidRedeemOrderFee(int256 provided);
    error InvalidAssetRescueRescue(address token);
    error ExceededOutstandingBalance(uint256 requested, uint256 outstandingBalance);

    event UpdatedRedeemFee(uint256 oldFee, uint256 newFee);
    event UpdatedRedeemOrderFee(int256 oldFee, int256 newFee);
    event UpdatedTreasury(address oldTreasury, address newTreasury);
}
