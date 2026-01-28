// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYuzuProtoDefinitions {
    error FeeTooHigh(uint256 provided, uint256 max);
    error FeeOverMaxFee(uint256 feePpm, uint256 max);
    error InvalidAssetRescue(address token);
    error ExceededOutstandingBalance(uint256 requested, uint256 outstandingBalance);

    event UpdatedRedeemFee(uint256 oldFee, uint256 newFee);
    event UpdatedRedeemOrderFee(uint256 oldFee, uint256 newFee);
    event UpdatedFeeReceiver(address oldFeeReceiver, address newFeeReceiver);
    event UpdatedIsMintRestricted(bool oldValue, bool newValue);
    event UpdatedIsRedeemRestricted(bool oldValue, bool newValue);
    event UpdatedTreasury(address oldTreasury, address newTreasury);
}

interface IYuzuProtoV2Definitions {
    error ExceededMaxBurn(address owner, uint256 tokens, uint256 max);
}
