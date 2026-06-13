// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

struct Throttle {
    uint256 blockLimit;
    uint256 dailyLimit;
    uint256 lastBlock;
    uint256 usedInBlock;
    uint256 lastDay;
    uint256 usedInDay;
}

interface IYuzuThrottleDefinitions {
    error ExceededMintBlockLimit(uint256 assets, uint256 remaining);
    error ExceededMintDailyLimit(uint256 assets, uint256 remaining);
    error ExceededRedeemBlockLimit(uint256 assets, uint256 remaining);
    error ExceededRedeemDailyLimit(uint256 assets, uint256 remaining);

    event UpdatedMintThrottle(
        uint256 oldBlockLimit, uint256 newBlockLimit, uint256 oldDailyLimit, uint256 newDailyLimit
    );
    event UpdatedRedeemThrottle(
        uint256 oldBlockLimit, uint256 newBlockLimit, uint256 oldDailyLimit, uint256 newDailyLimit
    );
}
