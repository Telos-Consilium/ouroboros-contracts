// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {YuzuV3FacetBase} from "./YuzuV3FacetBase.sol";
import {IYuzuILPDefinitions, IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {IYuzuProto} from "./interfaces/proto/IYuzuProto.sol";
import {
    BURNER_ROLE,
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    MAX_MANAGEMENT_FEE_PPM,
    MAX_PERFORMANCE_FEE_PPM,
    MINTER_ROLE,
    ORDER_FILLER_ROLE,
    POOL_MANAGER_ROLE,
    PRICE_GUARD_MANAGER_ROLE,
    REDEEMER_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./libraries/YuzuV3Constants.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";
import {YuzuV3Throttle} from "./libraries/YuzuV3Throttle.sol";
import {IYuzuMinAmountsDefinitions, IYuzuProtoV2Definitions} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuILPV3FacetPricing, IYuzuILPV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {
    YuzuILPDistributionV3Storage,
    YuzuILPFeesV3Storage,
    YuzuMinAmountsV3Storage,
    YuzuThrottleV3Storage
} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuILPV3Facet
 * @dev Fee and pricing math reads state through the vault's external interface so every path prices
 * from one implementation; storage writes and the pool state machine use the pinned slots below.
 */
// slither-disable-next-line missing-inheritance
contract YuzuILPV3Facet is
    YuzuV3FacetBase,
    IYuzuILPV3FacetPricing,
    IYuzuILPDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions,
    IYuzuProtoV2Definitions,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions
{
    /// @notice Maximum daily linear yield rate, in ppm (1% per day)
    uint256 internal constant MAX_DAILY_YIELD_PPM = 10_000;

    // Storage replicas
    uint256 private constant YUZU_ILP_POOL_SIZE_SLOT = 55;
    uint256 private constant YUZU_ILP_DAILY_LINEAR_YIELD_RATE_PPM_SLOT = 56;
    uint256 private constant YUZU_ILP_LAST_POOL_UPDATE_TIMESTAMP_SLOT = 57;
    uint256 private constant YUZU_ILPV2_IS_UPDATING_POOL_SLOT = 100;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTED_AMOUNT_SLOT = 101;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTION_PERIOD_SLOT = 102;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTION_TIMESTAMP_SLOT = 103;
    uint256 private constant YUZU_ILPV2_FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT = 104;
    uint256 private constant YUZU_ILPV2_REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT = 105;

    // User actions
    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        _checkMinDeposit(router, assets);
        uint256 maxAssets = _maxDeposit(address(this), receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 tokens = router.previewDeposit(assets);
        uint256 fee = YuzuV3Fees.feeOnTotal(assets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
        uint256 netAssets = assets - fee;
        _consumeMintThrottle(receiver, netAssets);
        _applyPoolSizeCredit(router, netAssets);
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, router.feeReceiver(), fee);
        }
        router.__routerDeposit(msg.sender, receiver, netAssets, tokens);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) external returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        uint256 assets = router.previewMint(tokens);
        if (tokens > 0 && assets == 0) {
            revert ZeroTotalAssets();
        }
        _checkMinDeposit(router, assets);
        uint256 maxTokens = _maxMint(address(this), receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }
        uint256 fee = YuzuV3Fees.feeOnTotal(assets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
        uint256 netAssets = assets - fee;
        _consumeMintThrottle(receiver, netAssets);
        _applyPoolSizeCredit(router, netAssets);
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, router.feeReceiver(), fee);
        }
        router.__routerDeposit(msg.sender, receiver, netAssets, tokens);
        return assets;
    }

    function burn(uint256 tokens) external {
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        address owner = msg.sender;
        uint256 maxTokens = IAccessControl(address(this)).hasRole(BURNER_ROLE, owner) ? router.balanceOf(owner) : 0;
        if (tokens > maxTokens) {
            revert ExceededMaxBurn(owner, tokens, maxTokens);
        }
        router.__routerBurn(owner, tokens);
    }

    /// @dev Splits the redemption between the pool and distribution buckets so neither bears the
    /// other's share, restating the fee-net redemption gross of accrued V3 fees first.
    function fillRedeemOrder(uint256 orderId) external {
        _checkRole(ORDER_FILLER_ROLE);
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        Order storage order = _getYuzuOrderBookStorage()._orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        // The order owner must still be an allowed redeemer at fill; pause is checked in finalizeRedeemOrder, not here.
        if (
            IYuzuProto(address(this)).isRedeemRestricted()
                && !IAccessControl(address(this)).hasRole(REDEEMER_ROLE, order.owner)
        ) {
            revert OrderOwnerNotRedeemer(orderId, order.owner);
        }
        (uint256 assets, uint256 fee) = _orderValue(router, order.tokens, order.feePpm);

        uint256 grossAssets = _proxyGrossTotalAssets(router, Math.Rounding.Floor);
        uint256 grossRedeemed = assets + fee;
        uint256 netTotalAssets = _proxyTotalAssets(router, Math.Rounding.Floor);
        if (netTotalAssets > 0) {
            grossRedeemed = Math.mulDiv(assets + fee, grossAssets, netTotalAssets, Math.Rounding.Ceil);
        }
        uint256 totalAssetsFromDistributions = router.netDistributedSinceUpdate();
        uint256 redeemFromDistributions =
            grossAssets > 0 ? Math.mulDiv(grossRedeemed, totalAssetsFromDistributions, grossAssets) : 0;
        uint256 redeemedFromPool = grossRedeemed - redeemFromDistributions;

        order.status = OrderStatus.Filled;
        order.assets = assets;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;
        $._totalUnfinalizedOrderValue += assets;
        _setRedeemedDistributionsSinceUpdate(_redeemedDistributionsSinceUpdate() + redeemFromDistributions);
        // The payout is priced fee-net while the pool gives up fee-free units, so the fee on the
        // redeemed units is already settled here. Shrink the credited fee-time claim by the same
        // fraction so the remaining holders are not charged for it a second time.
        uint256 poolUnitsRemoved = _proxyDiscountYield(router, redeemedFromPool, Math.Rounding.Ceil);
        uint256 poolBefore = router.poolSize();
        YuzuILPFeesV3Storage.Layout storage fees = YuzuILPFeesV3Storage.layout();
        if (poolBefore > 0) {
            fees._creditSecondsSinceUpdate = Math.mulDiv(
                fees._creditSecondsSinceUpdate, poolBefore - poolUnitsRemoved, poolBefore, Math.Rounding.Floor
            );
        }
        _setPoolSize(poolBefore - poolUnitsRemoved);

        router.__routerBurn(address(this), order.tokens);
        SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, address(this), assets);

        // slither-disable-next-line reentrancy-events
        emit FilledRedeemOrder(msg.sender, order.receiver, order.owner, orderId, assets, order.tokens, fee);
    }

    // Views
    function maxDeposit(address receiver) public view returns (uint256) {
        return _maxDeposit(msg.sender, receiver);
    }

    function maxMint(address receiver) public view returns (uint256) {
        return _maxMint(msg.sender, receiver);
    }

    function totalAssetsWithRounding(uint256 rounding) external view returns (uint256) {
        return _proxyTotalAssets(IYuzuILPV3Router(msg.sender), Math.Rounding(rounding));
    }

    /// @dev Floor rounded, matching the pricing path.
    function grossTotalAssets() external view returns (uint256) {
        return _proxyGrossTotalAssets(IYuzuILPV3Router(msg.sender), Math.Rounding.Floor);
    }

    /// @dev Ceil rounded, matching what the next update books before capping to the reported pool.
    function accruedManagementFee() external view returns (uint256) {
        return _proxyManagementFee(IYuzuILPV3Router(msg.sender), Math.Rounding.Ceil);
    }

    /// @dev Ceil rounded, on the current fee-net-of-management value. The next update realizes
    /// against the reported pool instead, so this is the live estimate.
    function accruedPerformanceFee() external view returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(msg.sender);
        uint256 managementFee = _proxyManagementFee(router, Math.Rounding.Ceil);
        uint256 gross = _proxyGrossTotalAssets(router, Math.Rounding.Floor);
        uint256 netOfManagementFee = gross > managementFee ? gross - managementFee : 0;
        return _proxyPerformanceFee(router, netOfManagementFee, Math.Rounding.Ceil);
    }

    // Pool operations
    /// @dev Applies V3 fees, then runs the V2 pool-update state transition on the net pool.
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) public {
        _checkRole(POOL_MANAGER_ROLE);
        if (newDailyLinearYieldRatePpm > MAX_DAILY_YIELD_PPM) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();

        uint256 accruedMgmtFee = _proxyManagementFee(router, Math.Rounding.Ceil);
        uint256 managementFee = Math.min(accruedMgmtFee, newPoolSize);
        uint256 netOfManagementFee = newPoolSize - managementFee;
        uint256 performanceFee = _proxyPerformanceFee(router, netOfManagementFee, Math.Rounding.Ceil);
        uint256 netPool = netOfManagementFee > performanceFee ? netOfManagementFee - performanceFee : 0;

        if (managementFee > 0) {
            uint256 cumulative = $._cumulativeManagementFees + managementFee;
            $._cumulativeManagementFees = cumulative;
            emit RealizedManagementFee(managementFee, cumulative);
        }
        if (managementFee < accruedMgmtFee) {
            emit ManagementFeeShortfall(accruedMgmtFee, managementFee, netPool);
        }
        if (performanceFee > 0) {
            uint256 cumulative = $._cumulativePerformanceFees + performanceFee;
            $._cumulativePerformanceFees = cumulative;
            emit RealizedPerformanceFee(performanceFee, cumulative);
        }

        $._managementFeeRatePpm = $._pendingManagementFeeRatePpm;

        uint256 supply = router.totalSupply();
        if (supply > 0) {
            uint256 newHighWaterMark = Math.mulDiv(netOfManagementFee, 10 ** router.decimals(), supply);
            if (newHighWaterMark > $._highWaterMark) {
                $._highWaterMark = newHighWaterMark;
            }
            $._performanceFeeRatePpm = $._pendingPerformanceFeeRatePpm;
        }

        _applyPoolUpdate(currentPoolSize, netPool, newDailyLinearYieldRatePpm);
    }

    /// @notice Update the pool and revert if the resulting share price leaves the band.
    function updatePool(
        uint256 currentPoolSize,
        uint256 newPoolSize,
        uint256 newDailyLinearYieldRatePpm,
        uint256 minSharePrice,
        uint256 maxSharePrice
    ) external {
        updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        _checkSharePriceWithin(router, _proxyTotalAssets(router, Math.Rounding.Floor), minSharePrice, maxSharePrice);
    }

    /// @notice Initiate a gradual increase in total assets.
    function distribute(uint256 assets, uint256 period) public {
        _checkRole(DISTRIBUTOR_ROLE);
        YuzuILPDistributionV3Storage.Layout storage distribution = YuzuILPDistributionV3Storage.layout();
        uint256 minPeriod = distribution._minDistributionPeriod;
        if (period < minPeriod) {
            revert DistributionPeriodTooLow(period, minPeriod);
        }
        if (period > 7 days) {
            revert DistributionPeriodTooHigh(period, 7 days);
        }
        uint256 maxPpm = distribution._maxDistributionPpm;
        if (maxPpm != type(uint256).max) {
            uint256 maxAssets = Math.mulDiv(IYuzuILPV3Router(address(this)).totalAssets(), maxPpm, 1e6);
            if (assets > maxAssets) {
                revert DistributionAmountTooHigh(assets, maxAssets);
            }
        }
        if (_isDistributionInProgress()) {
            revert DistributionInProgress();
        }

        _setFullyDistributedSinceUpdate(_fullyDistributedSinceUpdate() + _distributedAssets(Math.Rounding.Floor));
        _setLastDistributedAmount(assets);
        _setLastDistributionPeriod(period);
        _setLastDistributionTimestamp(block.timestamp);
        emit Distributed(assets, period);
    }

    /// @notice Distribute and revert if the projected end-of-distribution share price leaves the band.
    /// The projection nets out the performance fee the distributed amount will bear; it excludes
    /// management fee accruing over the vesting period and assumes supply and fee configuration do
    /// not change before completion.
    function distribute(uint256 assets, uint256 period, uint256 minSharePrice, uint256 maxSharePrice) external {
        distribute(assets, period);
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        _checkSharePriceWithin(
            router, _proxyTotalAssets(router, Math.Rounding.Floor, assets), minSharePrice, maxSharePrice
        );
    }

    /// @notice Terminate an in-progress distribution.
    function terminateDistribution() external {
        _checkRole(DISTRIBUTOR_ROLE);
        uint256 elapsedTime = block.timestamp - _lastDistributionTimestamp();
        if (_lastDistributionTimestamp() == 0 || elapsedTime >= _lastDistributionPeriod()) {
            revert NoDistributionInProgress();
        }
        uint256 distributed = _distributedAssets(Math.Rounding.Floor);
        uint256 undistributed = _lastDistributedAmount() - distributed;
        _setLastDistributedAmount(distributed);
        _setLastDistributionPeriod(elapsedTime);
        emit TerminatedDistribution(undistributed);
    }

    function startPoolUpdate() external {
        _checkRole(POOL_MANAGER_ROLE);
        assembly {
            sstore(YUZU_ILPV2_IS_UPDATING_POOL_SLOT, 1)
        }
    }

    function endPoolUpdate() external {
        _checkRole(POOL_MANAGER_ROLE);
        assembly {
            sstore(YUZU_ILPV2_IS_UPDATING_POOL_SLOT, 0)
        }
    }

    // Config setters
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    function setMintFee(uint256 newFeePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        uint256 oldFee = $._mintFeePpm;
        $._mintFeePpm = newFeePpm;
        emit UpdatedMintFee(oldFee, newFeePpm);
    }

    function setPendingManagementFee(uint256 newRatePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newRatePpm > MAX_MANAGEMENT_FEE_PPM) {
            revert FeeTooHigh(newRatePpm, MAX_MANAGEMENT_FEE_PPM);
        }
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        uint256 oldRatePpm = $._pendingManagementFeeRatePpm;
        $._pendingManagementFeeRatePpm = newRatePpm;
        emit UpdatedPendingManagementFee(oldRatePpm, newRatePpm);
    }

    function setPendingPerformanceFee(uint256 newRatePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newRatePpm > MAX_PERFORMANCE_FEE_PPM) {
            revert FeeTooHigh(newRatePpm, MAX_PERFORMANCE_FEE_PPM);
        }
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        uint256 oldRatePpm = $._pendingPerformanceFeeRatePpm;
        $._pendingPerformanceFeeRatePpm = newRatePpm;
        emit UpdatedPendingPerformanceFee(oldRatePpm, newRatePpm);
    }

    function setMinDistributionPeriod(uint256 newPeriod) external {
        _checkRole(PRICE_GUARD_MANAGER_ROLE);
        if (newPeriod < 1 hours) {
            revert DistributionPeriodTooLow(newPeriod, 1 hours);
        }
        if (newPeriod > 7 days) {
            revert DistributionPeriodTooHigh(newPeriod, 7 days);
        }
        YuzuILPDistributionV3Storage.Layout storage $ = YuzuILPDistributionV3Storage.layout();
        uint256 oldPeriod = $._minDistributionPeriod;
        $._minDistributionPeriod = newPeriod;
        emit UpdatedMinDistributionPeriod(oldPeriod, newPeriod);
    }

    /// @notice Cap on a single distribution, in ppm of current total assets; type(uint256).max disables it
    function setMaxDistributionPpm(uint256 newMaxPpm) external {
        _checkRole(PRICE_GUARD_MANAGER_ROLE);
        YuzuILPDistributionV3Storage.Layout storage $ = YuzuILPDistributionV3Storage.layout();
        uint256 oldMaxPpm = $._maxDistributionPpm;
        $._maxDistributionPpm = newMaxPpm;
        emit UpdatedMaxDistributionPpm(oldMaxPpm, newMaxPpm);
    }

    // State-machine internals
    function _applyPoolUpdate(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        private
    {
        uint256 pool = _poolSize();
        if (currentPoolSize != pool) {
            revert InvalidCurrentPoolSize(currentPoolSize, pool);
        }
        if (newDailyLinearYieldRatePpm > 1e6) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        if (_isDistributionInProgress()) {
            revert DistributionInProgress();
        }
        if (!_isUpdatingPool()) {
            revert NoPoolUpdateInProgress();
        }

        _setFullyDistributedSinceUpdate(0);
        _setRedeemedDistributionsSinceUpdate(0);

        YuzuILPFeesV3Storage.layout()._creditSecondsSinceUpdate = 0;

        _setLastDistributedAmount(0);
        _setLastDistributionPeriod(0);
        _setLastDistributionTimestamp(0);

        _setPoolSize(newPoolSize);
        _setDailyLinearYieldRatePpm(newDailyLinearYieldRatePpm);
        _setLastPoolUpdateTimestamp(block.timestamp);

        emit UpdatedPool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    function _checkSharePriceWithin(
        IYuzuILPV3Router router,
        uint256 totalAssets_,
        uint256 minSharePrice,
        uint256 maxSharePrice
    ) private view {
        uint256 supply = router.totalSupply();
        if (supply == 0) {
            return;
        }
        uint256 sharePrice = Math.mulDiv(totalAssets_, 10 ** router.decimals(), supply);
        if (sharePrice > maxSharePrice) {
            revert SharePriceTooHigh(sharePrice, maxSharePrice);
        }
        if (sharePrice < minSharePrice) {
            revert SharePriceTooLow(sharePrice, minSharePrice);
        }
    }

    // Pricing internals
    /// @dev Credits poolSize with an increment whose fee-net value equals {assets}, and records the
    /// credit against the fee-time basis so the deposit bears management fee only from now on.
    function _applyPoolSizeCredit(IYuzuILPV3Router router, uint256 assets) private {
        uint256 credit = _poolSizeCredit(router, assets);
        YuzuILPFeesV3Storage.layout()._creditSecondsSinceUpdate += credit * _proxyTimeSinceUpdate(router);
        _setPoolSize(router.poolSize() + credit);
    }

    /// @dev Returns the poolSize increment whose fee-net value equals {assets} now. The deposit is
    /// first restated gross of the performance fee it will bear, then discounted by the yield the
    /// enlarged poolSize will earn over the period already elapsed. Management fee needs no term
    /// here: the fee-time basis charges the credited units only from the moment they are credited.
    /// Reverts when no credit can match the deposit, leaving deposits closed while that holds.
    function _poolSizeCredit(IYuzuILPV3Router router, uint256 assets) private view returns (uint256) {
        uint256 managementFee = _proxyManagementFee(router, Math.Rounding.Ceil);
        uint256 grossAssets = _proxyGrossTotalAssets(router, Math.Rounding.Floor);
        uint256 netOfManagementFee = grossAssets > managementFee ? grossAssets - managementFee : 0;
        uint256 netTotalAssets = _proxyTotalAssets(router, Math.Rounding.Floor);

        uint256 poolUnits = assets;
        if (netTotalAssets > 0) {
            poolUnits = Math.mulDiv(assets, netOfManagementFee, netTotalAssets, Math.Rounding.Floor);
        } else if (netOfManagementFee > 0) {
            // Fees have consumed every asset backing the shares, so no credit prices the deposit.
            revert PoolFeeEroded();
        }
        return _proxyDiscountYield(router, poolUnits, Math.Rounding.Floor);
    }

    function _proxyTotalAssets(IYuzuILPV3Router router, Math.Rounding rounding) private view returns (uint256) {
        return _proxyTotalAssets(router, rounding, 0);
    }

    /// @dev Fee-net value with {addedAssets} joined to the gross total, so a projected amount runs
    /// through the same management-net and performance-fee arithmetic as live pricing.
    function _proxyTotalAssets(IYuzuILPV3Router router, Math.Rounding rounding, uint256 addedAssets)
        private
        view
        returns (uint256)
    {
        Math.Rounding feeRounding = Math.Rounding(1 - uint256(rounding));
        uint256 total = _proxyGrossTotalAssets(router, rounding) + addedAssets;
        uint256 managementFee = _proxyManagementFee(router, feeRounding);
        uint256 netOfManagementFee = managementFee >= total ? 0 : total - managementFee;
        uint256 performanceFee = _proxyPerformanceFee(router, netOfManagementFee, feeRounding);
        return performanceFee >= netOfManagementFee ? 0 : netOfManagementFee - performanceFee;
    }

    /// @dev Total assets before V3 fee accrual: pool with linear yield plus net distributions.
    function _proxyGrossTotalAssets(IYuzuILPV3Router router, Math.Rounding rounding) private view returns (uint256) {
        return router.poolSize() + _proxyYieldSinceUpdate(router, rounding)
            + _proxyNetDistributedSinceUpdate(router, rounding);
    }

    function _proxyYieldSinceUpdate(IYuzuILPV3Router router, Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(
            router.poolSize() * router.dailyLinearYieldRatePpm(), _proxyTimeSinceUpdate(router), 1e6 days, rounding
        );
    }

    /// @dev Accrues the management fee over the fee-time basis: the seconds each pool unit has spent
    /// in the pool since the last update. Units credited or removed part-way through are weighted by
    /// the time they were actually present, so a deposit is never charged for the period before it
    /// arrived and a redemption is charged up to its departure.
    function _proxyManagementFee(IYuzuILPV3Router router, Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(_proxyFeeTimeBasis(router), router.managementFeeRatePpm(), 1e6 * 365 days, rounding);
    }

    function _proxyFeeTimeBasis(IYuzuILPV3Router router) private view returns (uint256) {
        uint256 basis = router.poolSize() * _proxyTimeSinceUpdate(router);
        uint256 credited = router.creditSecondsSinceUpdate();
        return basis > credited ? basis - credited : 0;
    }

    /// @dev Restates {assets} in last-update pool units by discounting the linear yield accrued since.
    function _proxyDiscountYield(IYuzuILPV3Router router, uint256 assets, Math.Rounding rounding)
        private
        view
        returns (uint256)
    {
        return Math.mulDiv(
            assets, 1e6 days, 1e6 days + router.dailyLinearYieldRatePpm() * _proxyTimeSinceUpdate(router), rounding
        );
    }

    function _proxyNetDistributedSinceUpdate(IYuzuILPV3Router router, Math.Rounding rounding)
        private
        view
        returns (uint256)
    {
        uint256 netDistributed = router.netDistributedSinceUpdate();
        if (rounding != Math.Rounding.Ceil) {
            return netDistributed;
        }

        uint256 period = router.lastDistributionPeriod();
        if (period == 0) {
            return netDistributed;
        }

        uint256 elapsed = block.timestamp - router.lastDistributionTimestamp();
        uint256 amount = router.lastDistributedAmount();
        uint256 roundedDistributed = Math.min(amount, Math.mulDiv(elapsed, amount, period, Math.Rounding.Ceil));
        uint256 flooredDistributed = Math.min(amount, Math.mulDiv(elapsed, amount, period, Math.Rounding.Floor));
        return netDistributed + roundedDistributed - flooredDistributed;
    }

    function _proxyPerformanceFee(IYuzuILPV3Router router, uint256 netOfManagementFee, Math.Rounding rounding)
        private
        view
        returns (uint256)
    {
        uint256 rate = router.performanceFeeRatePpm();
        uint256 supply = router.totalSupply();
        if (rate == 0 || supply == 0) {
            return 0;
        }
        uint256 highWaterMarkAssets =
            Math.mulDiv(router.highWaterMark(), supply, 10 ** router.decimals(), Math.Rounding(1 - uint256(rounding)));
        if (netOfManagementFee <= highWaterMarkAssets) {
            return 0;
        }
        return Math.mulDiv(rate, netOfManagementFee - highWaterMarkAssets, 1e6, rounding);
    }

    function _proxyTimeSinceUpdate(IYuzuILPV3Router router) private view returns (uint256) {
        return block.timestamp - router.lastPoolUpdateTimestamp();
    }

    // Distribution internals
    function _isDistributionInProgress() private view returns (bool) {
        return block.timestamp < _lastDistributionTimestamp() + _lastDistributionPeriod();
    }

    function _distributedAssets(Math.Rounding rounding) private view returns (uint256) {
        uint256 period = _lastDistributionPeriod();
        if (period == 0) {
            return 0;
        }
        return Math.min(
            _lastDistributedAmount(),
            Math.mulDiv(block.timestamp - _lastDistributionTimestamp(), _lastDistributedAmount(), period, rounding)
        );
    }

    // Limit and guard helpers
    function _isThrottleExempt(address account) private view returns (bool) {
        return IAccessControl(address(this)).hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _maxDeposit(address proxy, address receiver) private view returns (uint256) {
        if (!_canMint(proxy, receiver)) {
            return 0;
        }
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        if (_requiresZeroSupplyReconciliation(router)) {
            return 0;
        }
        if (_isPoolFeeEroded(router)) {
            return 0;
        }
        uint256 baseMax = _headroomBacking(router, _supplyHeadroom(proxy), Math.Rounding.Floor);
        uint256 netMax = Math.min(baseMax, _mintThrottleRemaining(proxy, receiver));
        uint256 fee = YuzuV3Fees.feeOnRaw(netMax, router.mintFeePpm());
        uint256 maxAssets = type(uint256).max - fee < netMax ? type(uint256).max : netMax + fee;
        uint256 min = router.minDeposit();
        return maxAssets < min ? 0 : maxAssets;
    }

    function _maxMint(address proxy, address receiver) private view returns (uint256) {
        if (!_canMint(proxy, receiver)) {
            return 0;
        }
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        if (_requiresZeroSupplyReconciliation(router)) {
            return 0;
        }
        if (router.totalSupply() > 0 && router.totalAssets() == 0) {
            return 0;
        }
        if (_isPoolFeeEroded(router)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 remaining = _mintThrottleRemaining(proxy, receiver);
        uint256 shares = _headroomBacking(router, headroom, Math.Rounding.Ceil) <= remaining
            ? headroom
            : router.convertToShares(remaining);
        uint256 min = router.minDeposit();
        return router.previewMint(shares) < min ? 0 : shares;
    }

    /// @dev Fee-net asset backing of the full share headroom, saturating to uint256.max when the quotient is
    /// unrepresentable so an unlimited throttle stays reachable. Ceil bounds a mint cost from above so the quote
    /// never exceeds the throttle; Floor bounds a deposit from below.
    function _headroomBacking(IYuzuILPV3Router router, uint256 headroom, Math.Rounding rounding)
        private
        view
        returns (uint256)
    {
        uint256 supply = router.totalSupply();
        if (supply == 0) {
            // convertToShares(1) is the zero-supply share-per-asset rate (10 ** decimalsOffset).
            uint256 rate = router.convertToShares(1);
            return rounding == Math.Rounding.Ceil ? Math.ceilDiv(headroom, rate) : headroom / rate;
        }
        // Source total assets at the conversion's own rounding, not the floor-only totalAssets(), so the
        // estimate matches the mint or deposit it bounds.
        uint256 totalAssets_ = _proxyTotalAssets(router, rounding);
        // high >= supply means totalAssets_ * headroom overflows the uint256 quotient
        // slither-disable-next-line unused-return
        (uint256 high,) = Math.mul512(totalAssets_, headroom);
        return high >= supply ? type(uint256).max : Math.mulDiv(totalAssets_, headroom, supply, rounding);
    }

    /// @dev With zero supply, entry remains closed while assets or an active distribution are unresolved;
    /// a clean zero-asset bootstrap remains open.
    function _requiresZeroSupplyReconciliation(IYuzuILPV3Router router) private view returns (bool) {
        if (router.totalSupply() != 0) {
            return false;
        }
        if (router.totalAssets() > 0) {
            return true;
        }
        return block.timestamp < router.lastDistributionTimestamp() + router.lastDistributionPeriod();
    }

    /// @dev True when entry stays closed while this condition holds: accrued management fee has
    /// reached the pool bucket plus its yield, or accrued fees leave no fee-net value to price the
    /// deposit against. The closure protects a depositor from entering a state where the next
    /// update would realize the standing fee claim against value the deposit itself supplied.
    function _isPoolFeeEroded(IYuzuILPV3Router router) private view returns (bool) {
        uint256 pool = router.poolSize();
        if (
            pool > 0
                && pool + _proxyYieldSinceUpdate(router, Math.Rounding.Floor)
                    <= _proxyManagementFee(router, Math.Rounding.Ceil)
        ) {
            return true;
        }
        if (_proxyTotalAssets(router, Math.Rounding.Floor) > 0) {
            return false;
        }
        return _proxyGrossTotalAssets(router, Math.Rounding.Floor) > _proxyManagementFee(router, Math.Rounding.Ceil);
    }

    function _canMint(address proxy, address receiver) private view returns (bool) {
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        return !router.isUpdatingPool() && !router.paused()
            && (!router.isMintRestricted() || IAccessControl(proxy).hasRole(MINTER_ROLE, receiver));
    }

    function _supplyHeadroom(address proxy) private view returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        uint256 supplyCap = router.cap();
        uint256 supply = router.totalSupply();
        return supply >= supplyCap ? 0 : supplyCap - supply;
    }

    function _mintThrottleRemaining(address proxy, address account) private view returns (uint256) {
        if (IAccessControl(proxy).hasRole(THROTTLE_EXEMPT_ROLE, account)) {
            return type(uint256).max;
        }
        Throttle memory throttle = IYuzuILPV3Router(proxy).getMintThrottle();
        (uint256 blockRemaining, uint256 dailyRemaining) = YuzuV3Throttle.remaining(throttle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _consumeMintThrottle(address account, uint256 assets) private {
        if (_isThrottleExempt(account)) {
            return;
        }
        YuzuV3Throttle.consumeMintChecked(YuzuThrottleV3Storage.layout()._mintThrottle, assets);
    }

    function _checkMinDeposit(IYuzuILPV3Router router, uint256 assets) private view {
        uint256 min = router.minDeposit();
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    // Storage accessors
    function _poolSize() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILP_POOL_SIZE_SLOT)
        }
    }

    function _setPoolSize(uint256 value) private {
        assembly {
            sstore(YUZU_ILP_POOL_SIZE_SLOT, value)
        }
    }

    function _setDailyLinearYieldRatePpm(uint256 value) private {
        assembly {
            sstore(YUZU_ILP_DAILY_LINEAR_YIELD_RATE_PPM_SLOT, value)
        }
    }

    function _setLastPoolUpdateTimestamp(uint256 value) private {
        assembly {
            sstore(YUZU_ILP_LAST_POOL_UPDATE_TIMESTAMP_SLOT, value)
        }
    }

    function _isUpdatingPool() private view returns (bool) {
        uint256 value;
        assembly {
            value := sload(YUZU_ILPV2_IS_UPDATING_POOL_SLOT)
        }
        return value != 0;
    }

    function _lastDistributedAmount() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILPV2_LAST_DISTRIBUTED_AMOUNT_SLOT)
        }
    }

    function _setLastDistributedAmount(uint256 value) private {
        assembly {
            sstore(YUZU_ILPV2_LAST_DISTRIBUTED_AMOUNT_SLOT, value)
        }
    }

    function _lastDistributionPeriod() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILPV2_LAST_DISTRIBUTION_PERIOD_SLOT)
        }
    }

    function _setLastDistributionPeriod(uint256 value) private {
        assembly {
            sstore(YUZU_ILPV2_LAST_DISTRIBUTION_PERIOD_SLOT, value)
        }
    }

    function _lastDistributionTimestamp() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILPV2_LAST_DISTRIBUTION_TIMESTAMP_SLOT)
        }
    }

    function _setLastDistributionTimestamp(uint256 value) private {
        assembly {
            sstore(YUZU_ILPV2_LAST_DISTRIBUTION_TIMESTAMP_SLOT, value)
        }
    }

    function _fullyDistributedSinceUpdate() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILPV2_FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT)
        }
    }

    function _setFullyDistributedSinceUpdate(uint256 value) private {
        assembly {
            sstore(YUZU_ILPV2_FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT, value)
        }
    }

    function _redeemedDistributionsSinceUpdate() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILPV2_REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT)
        }
    }

    function _setRedeemedDistributionsSinceUpdate(uint256 value) private {
        assembly {
            sstore(YUZU_ILPV2_REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT, value)
        }
    }
}
