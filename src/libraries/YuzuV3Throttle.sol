// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Throttle} from "../interfaces/proto/IYuzuThrottleDefinitions.sol";

library YuzuV3Throttle {
    function remaining(Throttle memory throttle)
        internal
        view
        returns (uint256 blockRemaining, uint256 dailyRemaining)
    {
        uint256 blockLimit = throttle.blockLimit;
        uint256 usedInBlock = throttle.lastBlock == block.number ? throttle.usedInBlock : 0;
        blockRemaining = usedInBlock >= blockLimit ? 0 : blockLimit - usedInBlock;

        uint256 dailyLimit = throttle.dailyLimit;
        uint256 usedInDay = throttle.lastDay == currentDay() ? throttle.usedInDay : 0;
        dailyRemaining = usedInDay >= dailyLimit ? 0 : dailyLimit - usedInDay;
    }

    function consume(Throttle storage throttle, uint256 assets) internal {
        throttle.usedInBlock = (throttle.lastBlock == block.number ? throttle.usedInBlock : 0) + assets;
        throttle.lastBlock = block.number;

        uint256 day = currentDay();
        throttle.usedInDay = (throttle.lastDay == day ? throttle.usedInDay : 0) + assets;
        throttle.lastDay = day;
    }

    function currentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
