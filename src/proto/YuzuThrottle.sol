// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuThrottleDefinitions, Throttle} from "../interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuV3Throttle} from "../libraries/YuzuV3Throttle.sol";
import {YuzuThrottleV3Storage} from "../storage/YuzuV3Storage.sol";

/**
 * @title YuzuThrottle
 * @notice Per-block and calendar-day mint/redeem limits
 * @dev Uses ERC-7201 namespaced storage. A limit of 0 halts the flow; max uint never binds.
 */
abstract contract YuzuThrottle is IYuzuThrottleDefinitions {
    /// @notice Returns the mint throttle limits and usage
    function getMintThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._mintThrottle;
    }

    /// @notice Returns the redeem throttle limits and usage
    function getRedeemThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._redeemThrottle;
    }

    /// @dev Exemption policy hook; throttles apply to every account unless overridden
    function _isThrottleExempt(address) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Returns the remaining mint throttle capacity for account in the current block and day, in assets
    function _mintThrottleRemaining(address account) internal view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) =
            YuzuV3Throttle.remaining(YuzuThrottleV3Storage.layout()._mintThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    /// @dev Returns the remaining redeem throttle capacity for account in the current block and day, in assets
    function _redeemThrottleRemaining(address account) internal view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) =
            YuzuV3Throttle.remaining(YuzuThrottleV3Storage.layout()._redeemThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _consumeMintThrottle(address account, uint256 assets) internal {
        if (_isThrottleExempt(account)) {
            return;
        }
        YuzuV3Throttle.consumeMintChecked(YuzuThrottleV3Storage.layout()._mintThrottle, assets);
    }

    function _consumeRedeemThrottle(address account, uint256 assets) internal {
        if (_isThrottleExempt(account)) {
            return;
        }
        YuzuV3Throttle.consumeRedeemChecked(YuzuThrottleV3Storage.layout()._redeemThrottle, assets);
    }

    function _setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) internal {
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function _setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) internal {
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }
}
