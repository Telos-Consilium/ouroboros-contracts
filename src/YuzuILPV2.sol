// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILP} from "./YuzuILP.sol";
import {IYuzuILPV2Definitions} from "./interfaces/IYuzuILPDefinitions.sol";

/**
 * @title YuzuILPV2
 * @notice YuzuILP with progressive distributions
 */
contract YuzuILPV2 is YuzuILP, IYuzuILPV2Definitions {
    uint256 public lastDistributedAmount;
    uint256 public lastDistributionPeriod;
    uint256 public lastDistributionTimestamp;

    // slither-disable-next-line pess-unprotected-initialize
    function initializeV2() external reinitializer(2) {
        lastDistributionPeriod = 1;
    }

    /// @notice See {YuzuILP-updatePool}
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        public
        override
    {
        if (_isDistributionInProgress()) {
            revert DistributionInProgress();
        }
        super.updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    /// @notice See {YuzuILP-distribute}
    function distribute(uint256 assets, uint256 period) external onlyRole(POOL_MANAGER_ROLE) {
        if (period < 1) {
            revert DistributionPeriodTooLow(period, 1);
        }
        if (period > 7 days) {
            revert DistributionPeriodTooHigh(period, 7 days);
        }
        if (_isDistributionInProgress()) {
            revert DistributionInProgress();
        }
        lastDistributedAmount = assets;
        lastDistributionPeriod = period;
        lastDistributionTimestamp = block.timestamp;
        emit Distributed(assets, period);
    }

    /// @notice See {YuzuILP-terminateDistribution}
    function terminateDistribution() external onlyRole(POOL_MANAGER_ROLE) {
        uint256 elapsedTime = block.timestamp - lastDistributionTimestamp;
        if (lastDistributionTimestamp == 0 || elapsedTime >= lastDistributionPeriod) {
            revert NoDistributionInProgress();
        }
        uint256 distributed = _distributedAssets(Math.Rounding.Floor);
        uint256 undistributed = lastDistributedAmount - distributed;
        lastDistributedAmount = distributed;
        lastDistributionPeriod = elapsedTime;
        emit TerminatedDistribution(undistributed);
    }

    function _totalAssets(Math.Rounding rounding) internal view override returns (uint256) {
        return super._totalAssets(rounding) + _distributedAssets(rounding);
    }

    function _isDistributionInProgress() internal view returns (bool) {
        return block.timestamp < lastDistributionTimestamp + lastDistributionPeriod;
    }

    function _distributedAssets(Math.Rounding rounding) internal view returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (lastDistributionPeriod == 0) {
            return 0;
        }
        return Math.min(
            lastDistributedAmount,
            Math.mulDiv(
                block.timestamp - lastDistributionTimestamp, lastDistributedAmount, lastDistributionPeriod, rounding
            )
        );
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
