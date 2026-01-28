// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILP, Order, OrderStatus} from "./YuzuILP.sol";
import {YuzuProto} from "./proto/YuzuProto.sol";
import {YuzuProtoV2} from "./proto/YuzuProtoV2.sol";
import {YuzuIssuer} from "./proto/YuzuIssuer.sol";
import {YuzuOrderBook} from "./proto/YuzuOrderBook.sol";
import {IYuzuILPV2Definitions} from "./interfaces/IYuzuILPDefinitions.sol";

/**
 * @title YuzuILPV2
 * @notice YuzuILP with progressive distributions and forced cancellations
 */
contract YuzuILPV2 is YuzuILP, YuzuProtoV2, IYuzuILPV2Definitions {
    bool public isUpdatingPool;

    uint256 public lastDistributedAmount;
    uint256 public lastDistributionPeriod;
    uint256 public lastDistributionTimestamp;

    uint256 internal _fullyDistributedSinceUpdate;
    uint256 internal _redeemedDistributionsSinceUpdate;

    /// @notice Reinitializes the contract for V2 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external reinitializer(2) {
        __YuzuProtoV2_init_unchained();
        __EIP712_init(name(), "2");
    }

    /// @inheritdoc YuzuILP
    function totalAssets() public view override(YuzuILP, YuzuIssuer) returns (uint256) {
        return YuzuILP.totalAssets();
    }

    /// @inheritdoc YuzuProtoV2
    function maxDeposit(address receiver) public view override(YuzuILP, YuzuProtoV2) returns (uint256) {
        return YuzuILP.maxDeposit(receiver);
    }

    /// @inheritdoc YuzuProtoV2
    function maxMint(address receiver) public view override(YuzuProto, YuzuProtoV2) returns (uint256) {
        return YuzuProtoV2.maxMint(receiver);
    }

    /// @inheritdoc YuzuProtoV2
    function maxWithdraw(address _owner) public view override(YuzuILP, YuzuProtoV2) returns (uint256) {
        return YuzuProtoV2.maxWithdraw(_owner);
    }

    /// @inheritdoc YuzuProtoV2
    function maxRedeem(address _owner) public view override(YuzuILP, YuzuProtoV2) returns (uint256) {
        return YuzuProtoV2.maxRedeem(_owner);
    }

    /// @inheritdoc YuzuProtoV2
    function maxRedeemOrder(address _owner) public view override(YuzuProto, YuzuProtoV2) returns (uint256) {
        return YuzuProtoV2.maxRedeemOrder(_owner);
    }

    /// @inheritdoc YuzuProtoV2
    function cancelRedeemOrder(uint256 orderId) public virtual override(YuzuProtoV2, YuzuOrderBook) {
        YuzuProtoV2.cancelRedeemOrder(orderId);
    }

    /// @inheritdoc YuzuProtoV2
    function canMint(address _owner) public view override returns (bool) {
        return !isUpdatingPool && super.canMint(_owner);
    }

    /// @inheritdoc YuzuProtoV2
    function canRedeem(address _owner) public view override returns (bool) {
        return false;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override(YuzuILP, YuzuIssuer)
    {
        YuzuILP._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares, uint256 fee)
        internal
        override(YuzuILP, YuzuProtoV2)
    {
        YuzuILP._withdraw(caller, receiver, _owner, assets, shares, fee);
    }

    function startPoolUpdate() external onlyRole(POOL_MANAGER_ROLE) {
        isUpdatingPool = true;
    }

    function endPoolUpdate() external onlyRole(POOL_MANAGER_ROLE) {
        isUpdatingPool = false;
    }

    /// @inheritdoc YuzuILP
    /// @dev Daily yield starts accruing on top of distributions at the next update after they are completed.
    /// @dev {newPoolSize} SHOULD include accrued linear yield (set with {updatePool}).
    /// @dev {newPoolSize} SHOULD include net distributed assets since the last update (set with {distribute}).
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        public
        virtual
        override
        onlyRole(POOL_MANAGER_ROLE)
    {
        if (currentPoolSize != poolSize) {
            revert InvalidCurrentPoolSize(currentPoolSize, poolSize);
        }
        if (newDailyLinearYieldRatePpm > 1e6) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        if (_isDistributionInProgress()) {
            revert DistributionInProgress();
        }
        if (!isUpdatingPool) {
            revert NoPoolUpdateInProgress();
        }

        _fullyDistributedSinceUpdate = 0;
        _redeemedDistributionsSinceUpdate = 0;

        lastDistributedAmount = 0;
        lastDistributionPeriod = 0;
        lastDistributionTimestamp = 0;

        poolSize = newPoolSize;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;

        emit UpdatedPool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    /// @notice Initiate a gradual increase in total assets
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
        /* 
         * Multiple distributions can take place between updates.
         * When a new one is initiated, the total distributed by the previous one is added to the accumulator,
         * which is reset on update.
         */
        _fullyDistributedSinceUpdate += _distributedAssets(Math.Rounding.Floor);
        lastDistributedAmount = assets;
        lastDistributionPeriod = period;
        lastDistributionTimestamp = block.timestamp;
        emit Distributed(assets, period);
    }

    /// @notice Terminate an in-progress distribution
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

    function distributedSinceUpdate() public view returns (uint256) {
        return _fullyDistributedSinceUpdate + _distributedAssets(Math.Rounding.Floor);
    }

    function netDistributedSinceUpdate() public view returns (uint256) {
        return distributedSinceUpdate() - _redeemedDistributionsSinceUpdate;
    }

    function _totalAssets(Math.Rounding rounding) internal view override returns (uint256) {
        return super._totalAssets(rounding) + _fullyDistributedSinceUpdate + _distributedAssets(rounding)
            - _redeemedDistributionsSinceUpdate;
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

    /// @notice Override to avoid double-counting distributed assets when decreasing poolSize
    function _fillRedeemOrder(address caller, Order storage order, uint256 assets, uint256 fee)
        internal
        override(YuzuILP, YuzuOrderBook)
    {
        uint256 totalAssetsFromPool = super._totalAssets(Math.Rounding.Floor);
        uint256 totalAssetsFromDistributions = netDistributedSinceUpdate();
        uint256 __totalAssets = totalAssetsFromPool + totalAssetsFromDistributions;
        uint256 redeemFromDistributions = 0;
        if (__totalAssets > 0) {
            redeemFromDistributions = Math.mulDiv(assets + fee, totalAssetsFromDistributions, __totalAssets);
        }
        uint256 redeemedFromPool = assets + fee - redeemFromDistributions;

        YuzuOrderBook._fillRedeemOrder(caller, order, assets, fee);

        _redeemedDistributionsSinceUpdate += redeemFromDistributions;
        poolSize -= _discountYield(redeemedFromPool, Math.Rounding.Ceil);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
