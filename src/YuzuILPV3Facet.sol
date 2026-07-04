// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuIssuerDefinitions} from "./interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuILPDefinitions, IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";
import {YuzuV3Throttle} from "./libraries/YuzuV3Throttle.sol";
import {
    IYuzuMinAmountsDefinitions,
    IYuzuProtoDefinitions,
    IYuzuProtoV2Definitions
} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuILPV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuILPFeesV3Storage, YuzuMinAmountsV3Storage, YuzuThrottleV3Storage} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuILPV3Facet
 */
contract YuzuILPV3Facet is
    IYuzuIssuerDefinitions,
    IYuzuOrderBookDefinitions,
    IYuzuProtoDefinitions,
    IYuzuILPDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions,
    IYuzuProtoV2Definitions,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Maximum daily linear yield rate, in ppm (1% per day)
    uint256 internal constant MAX_DAILY_YIELD_PPM = 10_000;

    /// @notice Maximum management fee, in ppm per year (10%)
    uint256 internal constant MAX_MANAGEMENT_FEE_PPM = 100_000;

    uint256 private constant YUZU_PROTO_TREASURY_SLOT = 1;
    uint256 private constant YUZU_PROTO_REDEEM_FEE_SLOT = 2;
    uint256 private constant YUZU_PROTO_REDEEM_ORDER_FEE_SLOT = 3;
    uint256 private constant YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT = 4;
    uint256 private constant IS_MINT_RESTRICTED_SHIFT = 160;
    uint256 private constant IS_REDEEM_RESTRICTED_SHIFT = 168;
    uint256 private constant YUZU_ILP_POOL_SIZE_SLOT = 55;
    uint256 private constant YUZU_ILP_DAILY_LINEAR_YIELD_RATE_PPM_SLOT = 56;
    uint256 private constant YUZU_ILP_LAST_POOL_UPDATE_TIMESTAMP_SLOT = 57;
    uint256 private constant YUZU_ILPV2_IS_UPDATING_POOL_SLOT = 100;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTED_AMOUNT_SLOT = 101;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTION_PERIOD_SLOT = 102;
    uint256 private constant YUZU_ILPV2_LAST_DISTRIBUTION_TIMESTAMP_SLOT = 103;
    uint256 private constant YUZU_ILPV2_FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT = 104;
    uint256 private constant YUZU_ILPV2_REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT = 105;

    struct YuzuIssuerStorage {
        uint256 _supplyCap;
        uint256 _liquidityBufferTargetSize;
    }

    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _totalPendingOrderSize;
        uint256 _totalUnfinalizedOrderValue;
        uint256 _orderCount;
        uint256 _minRedeemOrder;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation =
        0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    // External
    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        _checkMinDeposit(assets);
        uint256 maxAssets = _maxDeposit(address(this), receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 tokens = router.previewDeposit(assets);
        uint256 fee = YuzuV3Fees.feeOnTotal(assets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
        uint256 netAssets = assets - fee;
        _consumeMintThrottle(receiver, netAssets);
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, router.feeReceiver(), fee);
        }
        _applyPoolSizeCredit(netAssets);
        router.__routerDeposit(msg.sender, receiver, netAssets, tokens);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) external returns (uint256) {
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        uint256 assets = router.previewMint(tokens);
        if (tokens > 0 && assets == 0) {
            revert ZeroTotalAssets();
        }
        _checkMinDeposit(assets);
        uint256 maxTokens = _maxMint(address(this), receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }
        uint256 fee = YuzuV3Fees.feeOnTotal(assets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
        uint256 netAssets = assets - fee;
        _consumeMintThrottle(receiver, netAssets);
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, router.feeReceiver(), fee);
        }
        _applyPoolSizeCredit(netAssets);
        router.__routerDeposit(msg.sender, receiver, netAssets, tokens);
        return assets;
    }

    function withdrawCollateral(uint256 assets, address receiver) external {
        _checkRole(ADMIN_ROLE);
        IYuzuILPV3Router router = IYuzuILPV3Router(address(this));
        uint256 liquidityBuffer = router.liquidityBufferSize();
        if (assets == type(uint256).max) {
            assets = liquidityBuffer;
        } else if (assets > liquidityBuffer) {
            revert ExceededLiquidityBuffer(assets, liquidityBuffer);
        }
        SafeERC20.safeTransfer(IERC20(router.asset()), receiver, assets);
        emit WithdrawnCollateral(receiver, assets);
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
        uint256 grossAssets = router.convertToAssets(order.tokens);
        uint256 fee = YuzuV3Fees.feeOnTotal(grossAssets, order.feePpm);
        uint256 assets = grossAssets - fee;

        uint256 grossTotalAssets = _grossTotalAssets(Math.Rounding.Floor);
        uint256 grossRedeemed = grossAssets;
        uint256 netTotalAssets = _netTotalAssets(Math.Rounding.Floor);
        if (netTotalAssets > 0) {
            grossRedeemed = Math.mulDiv(grossAssets, grossTotalAssets, netTotalAssets, Math.Rounding.Ceil);
        }
        uint256 totalAssetsFromDistributions = _netDistributedSinceUpdate();
        uint256 redeemFromDistributions =
            grossTotalAssets > 0 ? Math.mulDiv(grossRedeemed, totalAssetsFromDistributions, grossTotalAssets) : 0;
        uint256 redeemedFromPool = grossRedeemed - redeemFromDistributions;

        order.status = OrderStatus.Filled;
        order.assets = assets;
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        $._totalPendingOrderSize -= order.tokens;
        $._totalUnfinalizedOrderValue += assets;
        _setRedeemedDistributionsSinceUpdate(_redeemedDistributionsSinceUpdate() + redeemFromDistributions);
        _setPoolSize(_poolSize() - _discountYield(redeemedFromPool, Math.Rounding.Ceil));

        router.__routerBurn(address(this), order.tokens);
        SafeERC20.safeTransferFrom(IERC20(router.asset()), msg.sender, address(this), assets);

        // slither-disable-next-line reentrancy-events
        emit FilledRedeemOrder(msg.sender, order.receiver, order.owner, orderId, assets, order.tokens, fee);
    }

    function maxDeposit(address receiver) public view returns (uint256) {
        return _maxDeposit(msg.sender, receiver);
    }

    function maxMint(address receiver) public view returns (uint256) {
        return _maxMint(msg.sender, receiver);
    }

    function totalAssetsWithRounding(uint256 rounding) external view returns (uint256) {
        return _proxyTotalAssets(msg.sender, Math.Rounding(rounding));
    }

    /// @dev Applies V3 fees, then runs the V2 pool-update state transition on the net pool.
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) public {
        _checkRole(POOL_MANAGER_ROLE);
        if (newDailyLinearYieldRatePpm > MAX_DAILY_YIELD_PPM) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();

        uint256 managementFee = _managementFeeSinceUpdate(Math.Rounding.Ceil);
        uint256 netOfManagementFee = newPoolSize > managementFee ? newPoolSize - managementFee : 0;
        uint256 performanceFee = _performanceFee(netOfManagementFee, Math.Rounding.Ceil);
        uint256 netPool = netOfManagementFee > performanceFee ? netOfManagementFee - performanceFee : 0;

        if (managementFee > 0) {
            uint256 cumulative = $._cumulativeManagementFees + managementFee;
            $._cumulativeManagementFees = cumulative;
            emit RealizedManagementFee(managementFee, cumulative);
        }
        if (performanceFee > 0) {
            uint256 cumulative = $._cumulativePerformanceFees + performanceFee;
            $._cumulativePerformanceFees = cumulative;
            emit RealizedPerformanceFee(performanceFee, cumulative);
        }

        $._managementFeeRatePpm = $._pendingManagementFeeRatePpm;

        uint256 supply = IERC20(address(this)).totalSupply();
        if (supply > 0) {
            uint256 newHwm = Math.mulDiv(netOfManagementFee, 10 ** IERC20Metadata(address(this)).decimals(), supply);
            if (newHwm > $._highWaterMark) {
                $._highWaterMark = newHwm;
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
        _checkSharePriceWithin(_netTotalAssets(Math.Rounding.Floor), minSharePrice, maxSharePrice);
    }

    /// @notice Initiate a gradual increase in total assets.
    function distribute(uint256 assets, uint256 period) public {
        _checkRole(POOL_MANAGER_ROLE);
        if (period < 1) {
            revert DistributionPeriodTooLow(period, 1);
        }
        if (period > 7 days) {
            revert DistributionPeriodTooHigh(period, 7 days);
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
    function distribute(uint256 assets, uint256 period, uint256 minSharePrice, uint256 maxSharePrice) external {
        distribute(assets, period);
        _checkSharePriceWithin(_netTotalAssets(Math.Rounding.Floor) + assets, minSharePrice, maxSharePrice);
    }

    /// @notice Terminate an in-progress distribution.
    function terminateDistribution() external {
        _checkRole(POOL_MANAGER_ROLE);
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

    function setTreasury(address newTreasury) external {
        _checkRole(ADMIN_ROLE);
        if (newTreasury == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldTreasury = IYuzuILPV3Router(address(this)).treasury();
        _setPackedAddress(YUZU_PROTO_TREASURY_SLOT, newTreasury);
        emit UpdatedTreasury(oldTreasury, newTreasury);
    }

    function setFeeReceiver(address newFeeReceiver) external {
        _checkRole(ADMIN_ROLE);
        if (newFeeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldFeeReceiver = IYuzuILPV3Router(address(this)).feeReceiver();
        _setPackedAddress(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, newFeeReceiver);
        emit UpdatedFeeReceiver(oldFeeReceiver, newFeeReceiver);
    }

    function setSupplyCap(uint256 newCap) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldCap = $._supplyCap;
        $._supplyCap = newCap;
        emit UpdatedSupplyCap(oldCap, newCap);
    }

    function setLiquidityBufferTargetSize(uint256 newSize) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        YuzuIssuerStorage storage $ = _getYuzuIssuerStorage();
        uint256 oldSize = $._liquidityBufferTargetSize;
        $._liquidityBufferTargetSize = newSize;
        emit UpdatedLiquidityBufferTargetSize(oldSize, newSize);
    }

    function setFillWindow(uint256 newWindow) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        if (newWindow > 365 days) {
            revert FillWindowTooHigh(newWindow, 365 days);
        }
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldWindow = $._fillWindow;
        $._fillWindow = newWindow;
        emit UpdatedFillWindow(oldWindow, newWindow);
    }

    function setMinRedeemOrder(uint256 newMin) external {
        _checkRole(REDEEM_MANAGER_ROLE);
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldMin = $._minRedeemOrder;
        $._minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }

    function setIsMintRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_MINT_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsMintRestricted(oldValue, restricted);
    }

    function setIsRedeemRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_REDEEM_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsRedeemRestricted(oldValue, restricted);
    }

    // slither-disable-next-line pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-event-setter
    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    // slither-disable-next-line pess-event-setter
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

    /// @dev Uses FEE_MANAGER_ROLE for all fee rates.
    // slither-disable-next-line pess-event-setter
    function setRedeemFee(uint256 newFeePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemFeePpm();
        _setRedeemFeePpm(newFeePpm);
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    // slither-disable-next-line pess-event-setter
    function setRedeemOrderFee(uint256 newFeePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemOrderFeePpm();
        _setRedeemOrderFeePpm(newFeePpm);
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    // slither-disable-next-line pess-event-setter
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

    // slither-disable-next-line pess-event-setter
    function setPendingPerformanceFee(uint256 newRatePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newRatePpm > 1e6) {
            revert FeeTooHigh(newRatePpm, 1e6);
        }
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        uint256 oldRatePpm = $._pendingPerformanceFeeRatePpm;
        $._pendingPerformanceFeeRatePpm = newRatePpm;
        emit UpdatedPendingPerformanceFee(oldRatePpm, newRatePpm);
    }

    // Internal
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

        _setLastDistributedAmount(0);
        _setLastDistributionPeriod(0);
        _setLastDistributionTimestamp(0);

        _setPoolSize(newPoolSize);
        _setDailyLinearYieldRatePpm(newDailyLinearYieldRatePpm);
        _setLastPoolUpdateTimestamp(block.timestamp);

        emit UpdatedPool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    function _checkSharePriceWithin(uint256 totalAssets_, uint256 minSharePrice, uint256 maxSharePrice) private view {
        uint256 supply = IERC20(address(this)).totalSupply();
        if (supply == 0) {
            return;
        }
        uint256 sharePrice = Math.mulDiv(totalAssets_, 10 ** IERC20Metadata(address(this)).decimals(), supply);
        if (sharePrice > maxSharePrice) {
            revert SharePriceTooHigh(sharePrice, maxSharePrice);
        }
        if (sharePrice < minSharePrice) {
            revert SharePriceTooLow(sharePrice, minSharePrice);
        }
    }

    /// @dev Credits poolSize with an increment whose fee-net value equals {assets}. Tokens are priced
    /// against fee-net total assets, while poolSize bears fee accrual for the full period since the
    /// last update; the credit keeps the share price unchanged and spares the deposit from fees
    /// accrued before it entered.
    function _applyPoolSizeCredit(uint256 assets) private {
        _setPoolSize(_poolSize() + _poolSizeCredit(assets));
    }

    /// @dev Returns the poolSize increment whose fee-net value equals {assets} now. Management fee
    /// accrues on poolSize but not on distributed assets, so the deposit is first restated gross of
    /// the performance fee, then converted into last-update pool units through the pool bucket's own
    /// net-of-management value. Falls back to the yield discount when the pool is empty. Reverts when
    /// accrued fees have consumed the pool's net value: pool units then add nothing, so no credit can
    /// match the deposit and deposits stay closed until the next pool update.
    function _poolSizeCredit(uint256 assets) private view returns (uint256) {
        uint256 pool = _poolSize();
        // slither-disable-next-line incorrect-equality
        if (pool == 0) {
            return _discountYield(assets, Math.Rounding.Floor);
        }
        uint256 managementFee = _managementFeeSinceUpdate(Math.Rounding.Ceil);
        uint256 grossTotalAssets = _grossTotalAssets(Math.Rounding.Floor);
        if (grossTotalAssets <= managementFee) {
            revert PoolFeeEroded();
        }
        uint256 netOfManagementFee = grossTotalAssets - managementFee;
        uint256 totalAssetsFromDistributions = _netDistributedSinceUpdate();
        if (netOfManagementFee <= totalAssetsFromDistributions) {
            revert PoolFeeEroded();
        }
        uint256 netTotalAssets = _netTotalAssets(Math.Rounding.Floor);
        // slither-disable-next-line incorrect-equality
        if (netTotalAssets == 0) {
            revert PoolFeeEroded();
        }
        uint256 poolNetOfManagementFee = netOfManagementFee - totalAssetsFromDistributions;
        return Math.mulDiv(
            Math.mulDiv(assets, netOfManagementFee, netTotalAssets, Math.Rounding.Floor),
            pool,
            poolNetOfManagementFee,
            Math.Rounding.Floor
        );
    }

    /// @dev Restates {assets} in last-update pool units by discounting the linear yield accrued since.
    function _discountYield(uint256 assets, Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(assets, 1e6 days, 1e6 days + _dailyLinearYieldRatePpm() * _timeSinceUpdate(), rounding);
    }

    /// @dev Total assets before V3 fee accrual: pool with linear yield plus net distributions.
    function _grossTotalAssets(Math.Rounding rounding) private view returns (uint256) {
        return _poolSize() + _yieldSinceUpdate(rounding) + _fullyDistributedSinceUpdate() + _distributedAssets(rounding)
            - _redeemedDistributionsSinceUpdate();
    }

    function _netDistributedSinceUpdate() private view returns (uint256) {
        return _fullyDistributedSinceUpdate() + _distributedAssets(Math.Rounding.Floor)
            - _redeemedDistributionsSinceUpdate();
    }

    function _netTotalAssets(Math.Rounding rounding) private view returns (uint256) {
        Math.Rounding feeRounding = Math.Rounding(1 - uint256(rounding));
        uint256 total = _grossTotalAssets(rounding);
        uint256 managementFee = _managementFeeSinceUpdate(feeRounding);
        uint256 netOfManagementFee = managementFee >= total ? 0 : total - managementFee;
        uint256 performanceFee = _performanceFee(netOfManagementFee, feeRounding);
        return performanceFee >= netOfManagementFee ? 0 : netOfManagementFee - performanceFee;
    }

    function _proxyTotalAssets(address proxy, Math.Rounding rounding) private view returns (uint256) {
        Math.Rounding feeRounding = Math.Rounding(1 - uint256(rounding));
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        uint256 pool = router.poolSize();
        uint256 total = pool
            + Math.mulDiv(pool * router.dailyLinearYieldRatePpm(), _proxyTimeSinceUpdate(router), 1e6 days, rounding)
            + _proxyNetDistributedSinceUpdate(router, rounding);
        uint256 managementFee = Math.mulDiv(
            pool * router.managementFeeRatePpm(), _proxyTimeSinceUpdate(router), 1e6 * 365 days, feeRounding
        );
        uint256 netOfManagementFee = managementFee >= total ? 0 : total - managementFee;
        uint256 performanceFee = _proxyPerformanceFee(router, netOfManagementFee, feeRounding);
        return performanceFee >= netOfManagementFee ? 0 : netOfManagementFee - performanceFee;
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
        uint256 hwmAssets =
            Math.mulDiv(router.highWaterMark(), supply, 10 ** router.decimals(), Math.Rounding(1 - uint256(rounding)));
        if (netOfManagementFee <= hwmAssets) {
            return 0;
        }
        return Math.mulDiv(rate, netOfManagementFee - hwmAssets, 1e6, rounding);
    }

    function _proxyTimeSinceUpdate(IYuzuILPV3Router router) private view returns (uint256) {
        return block.timestamp - router.lastPoolUpdateTimestamp();
    }

    function _managementFeeSinceUpdate(Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(_poolSize() * _managementFeeRatePpm(), _timeSinceUpdate(), 1e6 * 365 days, rounding);
    }

    function _performanceFee(uint256 netOfManagementFee, Math.Rounding rounding) private view returns (uint256) {
        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        uint256 rate = $._performanceFeeRatePpm;
        uint256 supply = IERC20(address(this)).totalSupply();
        if (rate == 0 || supply == 0) {
            return 0;
        }
        uint256 hwmAssets = Math.mulDiv(
            $._highWaterMark,
            supply,
            10 ** IERC20Metadata(address(this)).decimals(),
            Math.Rounding(1 - uint256(rounding))
        );
        if (netOfManagementFee <= hwmAssets) {
            return 0;
        }
        return Math.mulDiv(rate, netOfManagementFee - hwmAssets, 1e6, rounding);
    }

    function _yieldSinceUpdate(Math.Rounding rounding) private view returns (uint256) {
        return Math.mulDiv(_poolSize() * _dailyLinearYieldRatePpm(), _timeSinceUpdate(), 1e6 days, rounding);
    }

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

    function _checkRole(bytes32 role) private view {
        if (!IAccessControl(address(this)).hasRole(role, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, role);
        }
    }

    function _isThrottleExempt(address account) private view returns (bool) {
        return IAccessControl(address(this)).hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _maxDeposit(address proxy, address receiver) private view returns (uint256) {
        if (!_canMint(proxy, receiver)) {
            return 0;
        }
        IYuzuILPV3Router router = IYuzuILPV3Router(proxy);
        if (_isPoolFeeEroded(router)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 supply = router.totalSupply();
        uint256 baseMax;
        if (supply == 0) {
            baseMax = Math.ceilDiv(headroom, 1e12);
        } else {
            uint256 totalAssets_ = router.totalAssets();
            (uint256 high,) = Math.mul512(totalAssets_, headroom);
            baseMax = high >= supply ? type(uint256).max : Math.mulDiv(totalAssets_, headroom, supply);
        }
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
        if (router.totalSupply() > 0 && router.totalAssets() == 0) {
            return 0;
        }
        if (_isPoolFeeEroded(router)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 remaining = _mintThrottleRemaining(proxy, receiver);
        uint256 shares =
            remaining >= type(uint128).max ? headroom : Math.min(headroom, router.convertToShares(remaining));
        uint256 min = router.minDeposit();
        return router.previewMint(shares) < min ? 0 : shares;
    }

    /// @dev True when the accrued management fee has consumed the pool bucket's entire net value,
    /// leaving pool units with no marginal worth; deposits cannot be priced until the next pool update.
    function _isPoolFeeEroded(IYuzuILPV3Router router) private view returns (bool) {
        uint256 pool = router.poolSize();
        // slither-disable-next-line incorrect-equality
        if (pool == 0) {
            return false;
        }
        uint256 elapsed = _proxyTimeSinceUpdate(router);
        uint256 managementFee =
            Math.mulDiv(pool * router.managementFeeRatePpm(), elapsed, 1e6 * 365 days, Math.Rounding.Ceil);
        uint256 poolGross =
            pool + Math.mulDiv(pool * router.dailyLinearYieldRatePpm(), elapsed, 1e6 days, Math.Rounding.Floor);
        return poolGross <= managementFee;
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
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        (uint256 blockRemaining, uint256 dailyRemaining) = YuzuV3Throttle.remaining(throttle);
        if (assets > blockRemaining) {
            revert ExceededMintBlockLimit(assets, blockRemaining);
        }
        if (assets > dailyRemaining) {
            revert ExceededMintDailyLimit(assets, dailyRemaining);
        }
        YuzuV3Throttle.consume(throttle, assets);
    }

    function _checkMinDeposit(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minDeposit;
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    // Storage
    function _setPackedAddress(uint256 slot, address value) private {
        uint256 mask = type(uint160).max;
        assembly {
            let oldValue := sload(slot)
            sstore(slot, or(and(oldValue, not(mask)), and(value, mask)))
        }
    }

    function _setPackedBool(uint256 slot, uint256 shift, bool value) private returns (bool oldValue) {
        uint256 mask = 0xff << shift;
        uint256 oldSlot;
        assembly {
            oldSlot := sload(slot)
        }
        oldValue = ((oldSlot >> shift) & 0xff) != 0;
        uint256 newSlot = oldSlot & ~mask;
        if (value) {
            newSlot |= 1 << shift;
        }
        assembly {
            sstore(slot, newSlot)
        }
    }

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

    function _dailyLinearYieldRatePpm() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILP_DAILY_LINEAR_YIELD_RATE_PPM_SLOT)
        }
    }

    function _setDailyLinearYieldRatePpm(uint256 value) private {
        assembly {
            sstore(YUZU_ILP_DAILY_LINEAR_YIELD_RATE_PPM_SLOT, value)
        }
    }

    function _lastPoolUpdateTimestamp() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_ILP_LAST_POOL_UPDATE_TIMESTAMP_SLOT)
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

    function _redeemFeePpm() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_FEE_SLOT)
        }
    }

    function _setRedeemFeePpm(uint256 value) private {
        assembly {
            sstore(YUZU_PROTO_REDEEM_FEE_SLOT, value)
        }
    }

    function _redeemOrderFeePpm() private view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT)
        }
    }

    function _setRedeemOrderFeePpm(uint256 value) private {
        assembly {
            sstore(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT, value)
        }
    }

    function _timeSinceUpdate() private view returns (uint256) {
        return block.timestamp - _lastPoolUpdateTimestamp();
    }

    function _managementFeeRatePpm() private view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._managementFeeRatePpm;
    }

    function _getYuzuIssuerStorage() private pure returns (YuzuIssuerStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _getYuzuOrderBookStorage() private pure returns (YuzuOrderBookStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }
}
