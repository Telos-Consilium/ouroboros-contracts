// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuProtoDefinitions {
    error InvalidZeroAddress();
    error InvalidRedemptionFee(uint256 provided);
    error InvalidRedemptionOrderFee(int256 provided);
    error ExceededOutstandingBalance(uint256 requested, uint256 outstandingBalance);

    event UpdatedRedemptionFee(uint256 oldFee, uint256 newFee);
    event UpdatedRedemptionOrderFee(int256 oldFee, int256 newFee);
    event UpdatedTreasury(address oldTreasury, address newTreasury);
}
