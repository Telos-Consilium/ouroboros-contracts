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

interface IYuzuMinAmountsDefinitions {
    error UnderMinDeposit(uint256 assets, uint256 min);
    error UnderMinWithdraw(uint256 assets, uint256 min);

    event UpdatedMinDeposit(uint256 oldMin, uint256 newMin);
    event UpdatedMinWithdraw(uint256 oldMin, uint256 newMin);
}

interface IYuzuSameBlockGuardDefinitions {
    error SameBlockMintRedeem(address account);
}

interface IYuzuNavMarkdownDefinitions {
    error NavStepTooLarge(uint256 requestedNav, uint256 currentNav, uint256 maxDelta);
    error NavCooldownActive(uint256 nowTimestamp, uint256 readyTimestamp);
    error InvalidNavStepCap(uint256 stepCapPpm, uint256 max);
    error MintDisabledWhileMarkedDown(uint256 nav);

    event UpdatedNav(uint256 oldNav, uint256 newNav);
    event UpdatedNavStepCap(uint256 oldStepCapPpm, uint256 newStepCapPpm);
    event UpdatedNavCooldown(uint256 oldCooldown, uint256 newCooldown);
}
