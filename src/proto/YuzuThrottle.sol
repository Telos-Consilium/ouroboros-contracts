// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuThrottleDefinitions, Throttle} from "../interfaces/proto/IYuzuThrottleDefinitions.sol";

/**
 * @title YuzuThrottle
 * @notice Per-block and calendar-day rate limits on asset inflows (deposit/mint) and instant outflows (withdraw/redeem)
 * @dev Limits are enforced at face value: 0 halts the corresponding flow and type(uint256).max
 * never binds. Daily windows are UTC calendar days, so up to 2x the daily limit can flow across
 * a day boundary. Consumers define the exemption policy by overriding {_isThrottleExempt}.
 */
abstract contract YuzuThrottle is IYuzuThrottleDefinitions {
    struct YuzuThrottleStorage {
        Throttle _mintThrottle;
        Throttle _redeemThrottle;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.throttle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuThrottleStorageLocation =
        0x0b7c362ff29744eee18a40453a4b4ef5d7bd130da15027ce5dd041799a288e00;

    /// @notice Returns the mint throttle limits and usage
    function getMintThrottle() external view returns (Throttle memory) {
        return _getYuzuThrottleStorage()._mintThrottle;
    }

    /// @notice Returns the redeem throttle limits and usage
    function getRedeemThrottle() external view returns (Throttle memory) {
        return _getYuzuThrottleStorage()._redeemThrottle;
    }

    /// @dev Exemption policy hook; throttles apply to every account unless overridden
    function _isThrottleExempt(address) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Returns the remaining mint throttle capacity for {account} in the current block and day, in assets
    function _mintThrottleRemaining(address account) internal view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(_getYuzuThrottleStorage()._mintThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    /// @dev Returns the remaining redeem throttle capacity for {account} in the current block and day, in assets
    function _redeemThrottleRemaining(address account) internal view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(_getYuzuThrottleStorage()._redeemThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _consumeMintThrottle(address account, uint256 assets) internal {
        if (_isThrottleExempt(account)) {
            return;
        }
        Throttle storage throttle = _getYuzuThrottleStorage()._mintThrottle;
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(throttle);
        if (assets > blockRemaining) {
            revert ExceededMintBlockLimit(assets, blockRemaining);
        }
        if (assets > dailyRemaining) {
            revert ExceededMintDailyLimit(assets, dailyRemaining);
        }
        _consume(throttle, assets);
    }

    function _consumeRedeemThrottle(address account, uint256 assets) internal {
        if (_isThrottleExempt(account)) {
            return;
        }
        Throttle storage throttle = _getYuzuThrottleStorage()._redeemThrottle;
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(throttle);
        if (assets > blockRemaining) {
            revert ExceededRedeemBlockLimit(assets, blockRemaining);
        }
        if (assets > dailyRemaining) {
            revert ExceededRedeemDailyLimit(assets, dailyRemaining);
        }
        _consume(throttle, assets);
    }

    function _setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) internal {
        Throttle storage throttle = _getYuzuThrottleStorage()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function _setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) internal {
        Throttle storage throttle = _getYuzuThrottleStorage()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function _remaining(Throttle storage throttle)
        private
        view
        returns (uint256 blockRemaining, uint256 dailyRemaining)
    {
        uint256 blockLimit = throttle.blockLimit;
        // slither-disable-next-line incorrect-equality
        uint256 usedInBlock = throttle.lastBlock == block.number ? throttle.usedInBlock : 0;
        blockRemaining = usedInBlock >= blockLimit ? 0 : blockLimit - usedInBlock;

        uint256 dailyLimit = throttle.dailyLimit;
        // slither-disable-next-line incorrect-equality
        uint256 usedInDay = throttle.lastDay == _currentDay() ? throttle.usedInDay : 0;
        dailyRemaining = usedInDay >= dailyLimit ? 0 : dailyLimit - usedInDay;
    }

    function _consume(Throttle storage throttle, uint256 assets) private {
        // slither-disable-next-line incorrect-equality
        throttle.usedInBlock = (throttle.lastBlock == block.number ? throttle.usedInBlock : 0) + assets;
        throttle.lastBlock = block.number;

        uint256 day = _currentDay();
        // slither-disable-next-line incorrect-equality
        throttle.usedInDay = (throttle.lastDay == day ? throttle.usedInDay : 0) + assets;
        throttle.lastDay = day;
    }

    function _currentDay() private view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _getYuzuThrottleStorage() private pure returns (YuzuThrottleStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuThrottleStorageLocation
        }
    }
}
