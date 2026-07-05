// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuThrottleDefinitions, Throttle} from "../interfaces/proto/IYuzuThrottleDefinitions.sol";

library YuzuV3Throttle {
    function consumeMintChecked(Throttle storage throttle, uint256 assets) internal {
        (uint256 blockRemaining, uint256 dailyRemaining) = remaining(throttle);
        if (assets > blockRemaining) {
            revert IYuzuThrottleDefinitions.ExceededMintBlockLimit(assets, blockRemaining);
        }
        if (assets > dailyRemaining) {
            revert IYuzuThrottleDefinitions.ExceededMintDailyLimit(assets, dailyRemaining);
        }
        consume(throttle, assets);
    }

    function consumeRedeemChecked(Throttle storage throttle, uint256 assets) internal {
        (uint256 blockRemaining, uint256 dailyRemaining) = remaining(throttle);
        if (assets > blockRemaining) {
            revert IYuzuThrottleDefinitions.ExceededRedeemBlockLimit(assets, blockRemaining);
        }
        if (assets > dailyRemaining) {
            revert IYuzuThrottleDefinitions.ExceededRedeemDailyLimit(assets, dailyRemaining);
        }
        consume(throttle, assets);
    }

    function remaining(Throttle memory throttle)
        internal
        view
        returns (uint256 blockRemaining, uint256 dailyRemaining)
    {
        uint256 blockLimit = throttle.blockLimit;
        // Same-window equality checks are the throttle design, not a manipulable condition
        // slither-disable-next-line incorrect-equality
        uint256 usedInBlock = throttle.lastBlock == block.number ? throttle.usedInBlock : 0;
        blockRemaining = usedInBlock >= blockLimit ? 0 : blockLimit - usedInBlock;

        uint256 dailyLimit = throttle.dailyLimit;
        // slither-disable-next-line incorrect-equality
        uint256 usedInDay = throttle.lastDay == currentDay() ? throttle.usedInDay : 0;
        dailyRemaining = usedInDay >= dailyLimit ? 0 : dailyLimit - usedInDay;
    }

    function consume(Throttle storage throttle, uint256 assets) internal {
        // slither-disable-next-line incorrect-equality
        throttle.usedInBlock = (throttle.lastBlock == block.number ? throttle.usedInBlock : 0) + assets;
        throttle.lastBlock = block.number;

        uint256 day = currentDay();
        // slither-disable-next-line incorrect-equality
        throttle.usedInDay = (throttle.lastDay == day ? throttle.usedInDay : 0) + assets;
        throttle.lastDay = day;
    }

    function currentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
