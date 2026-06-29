// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILPV2} from "./YuzuILPV2.sol";
import {IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {IYuzuILPV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {Order} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuOrderBook} from "./proto/YuzuOrderBook.sol";
import {YuzuILPFeesV3Storage, YuzuMinAmountsV3Storage, YuzuThrottleV3Storage} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuILPV3
 * @notice YuzuILP with minimum mint amounts, per-block/daily throttling, a tighter daily yield ceiling,
 * optional share-price bounds on pool updates and distributions, a mint fee, a continuous management fee,
 * and a high-water-mark performance fee
 * @dev yzILP has no instant redeem (only redeem orders), so the redeem throttle and minWithdraw floor
 * never bind; the order path is unguarded. THROTTLE_EXEMPT_ROLE holders bypass the throttle. Fee rates are
 * under FEE_MANAGER_ROLE; management and performance rate changes take effect at the next pool update.
 */
contract YuzuILPV3 is YuzuILPV2, IYuzuILPV3Definitions {
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    address private immutable _facet;

    constructor(address facet_) {
        if (facet_ == address(0)) {
            revert InvalidZeroAddress();
        }
        _facet = facet_;
    }

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        YuzuThrottleV3Storage.Layout storage $ = YuzuThrottleV3Storage.layout();
        $._mintThrottle.blockLimit = type(uint256).max;
        $._mintThrottle.dailyLimit = type(uint256).max;
        $._redeemThrottle.blockLimit = type(uint256).max;
        $._redeemThrottle.dailyLimit = type(uint256).max;
    }

    /// @dev Applies the tighter V3 yield ceiling, realizes the management fee then the performance fee
    /// accrued since the last update against the admin-reported gross {newPoolSize}, advances the
    /// high-water mark, promotes the staged fee rates, then runs the inherited logic on the net
    function updatePool(uint256, uint256, uint256) public virtual override {
        _delegateToFacet();
    }

    /// @notice Update the pool and revert if the resulting share price leaves the band
    function updatePool(uint256, uint256, uint256, uint256, uint256) external virtual {
        _delegateToFacet();
    }

    /// @notice Initiate a gradual increase in total assets
    function distribute(uint256, uint256) public virtual override {
        _delegateToFacet();
    }

    /// @notice Distribute and revert if the projected end-of-distribution share price leaves the band
    function distribute(uint256, uint256, uint256, uint256) external virtual {
        _delegateToFacet();
    }

    /// @notice Terminate an in-progress distribution
    function terminateDistribution() external virtual override {
        _delegateToFacet();
    }

    function startPoolUpdate() external virtual override {
        _delegateToFacet();
    }

    function endPoolUpdate() external virtual override {
        _delegateToFacet();
    }

    function setTreasury(address) external virtual override {
        _delegateToFacet();
    }

    function setFeeReceiver(address) external virtual override {
        _delegateToFacet();
    }

    function setSupplyCap(uint256) external virtual override {
        _delegateToFacet();
    }

    function setLiquidityBufferTargetSize(uint256) external virtual override {
        _delegateToFacet();
    }

    function setFillWindow(uint256) external virtual override {
        _delegateToFacet();
    }

    function setMinRedeemOrder(uint256) external virtual override {
        _delegateToFacet();
    }

    function setIsMintRestricted(bool) external virtual override {
        _delegateToFacet();
    }

    function setIsRedeemRestricted(bool) external virtual override {
        _delegateToFacet();
    }

    function minDeposit() public view returns (uint256) {
        return YuzuMinAmountsV3Storage.layout()._minDeposit;
    }

    function getMintThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._mintThrottle;
    }

    /// @notice Fee charged on the deposit/mint path, in ppm of the assets in
    function mintFeePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._mintFeePpm;
    }

    /// @notice Active management fee, in ppm per year, charged as a continuous drift on poolSize
    function managementFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._managementFeeRatePpm;
    }

    /// @notice Management fee staged to take effect at the next pool update
    function pendingManagementFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._pendingManagementFeeRatePpm;
    }

    /// @notice Total management fees withheld to the treasury, never credited to holders
    function cumulativeManagementFees() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._cumulativeManagementFees;
    }

    /// @notice Active performance fee, in ppm, charged on the gain above the high-water mark
    function performanceFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._performanceFeeRatePpm;
    }

    /// @notice Performance fee staged to take effect at the next pool update
    function pendingPerformanceFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._pendingPerformanceFeeRatePpm;
    }

    /// @notice Highest net-of-management share price the fee has marked, in asset units per whole share
    function highWaterMark() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._highWaterMark;
    }

    /// @notice Total performance fees withheld to the treasury, never credited to holders
    function cumulativePerformanceFees() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._cumulativePerformanceFees;
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256, uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintFee(uint256) external virtual {
        _delegateToFacet();
    }

    /// @dev Re-homed from REDEEM_MANAGER_ROLE so all fee rates sit under FEE_MANAGER_ROLE
    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemFee(uint256) external virtual override {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemOrderFee(uint256) external virtual override {
        _delegateToFacet();
    }

    /// @dev Stages the rate; it takes effect at the next pool update, so a period is always charged at one
    /// rate fixed at its start. Deferral also keeps the drift from ever accruing before the first update.
    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setManagementFee(uint256) external virtual {
        _delegateToFacet();
    }

    /// @dev Stages the rate; it takes effect at the next pool update. The fee is charged on the share-price
    /// gain above the high-water mark, which advances at each update, so enabling the fee is never retroactive.
    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setPerformanceFee(uint256) external virtual {
        _delegateToFacet();
    }

    function maxDeposit(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (ILP share price is admin-set and unbounded).
    function maxMint(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    function deposit(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function mint(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function withdrawCollateral(uint256, address) public virtual override {
        _delegateToFacet();
    }

    function burn(uint256) public virtual override {
        _delegateToFacet();
    }

    function _fillRedeemOrder(address caller, Order storage order, uint256 assets, uint256 fee)
        internal
        virtual
        override(YuzuILPV2)
    {
        uint256 netRedeemed = assets + fee;
        uint256 grossTotalAssets = super._totalAssets(Math.Rounding.Floor);
        uint256 grossRedeemed = netRedeemed;
        uint256 netTotalAssets = _totalAssets(Math.Rounding.Floor);
        if (netTotalAssets > 0) {
            grossRedeemed = Math.mulDiv(netRedeemed, grossTotalAssets, netTotalAssets, Math.Rounding.Ceil);
        }

        uint256 totalAssetsFromDistributions = netDistributedSinceUpdate();
        uint256 redeemFromDistributions =
            grossTotalAssets > 0 ? Math.mulDiv(grossRedeemed, totalAssetsFromDistributions, grossTotalAssets) : 0;
        uint256 redeemedFromPool = grossRedeemed - redeemFromDistributions;

        YuzuOrderBook._fillRedeemOrder(caller, order, assets, fee);

        _redeemedDistributionsSinceUpdate += redeemFromDistributions;
        poolSize -= _discountYield(redeemedFromPool, Math.Rounding.Ceil);
    }

    function _totalAssets(Math.Rounding rounding) internal view override(YuzuILPV2) returns (uint256) {
        return IYuzuILPV3Router(_facet).totalAssetsWithRounding(uint256(rounding));
    }

    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external {
        _requireRouterSelfCall();
        _deposit(caller, receiver, assets, tokens);
    }

    function __routerBurn(address owner, uint256 tokens) external {
        _requireRouterSelfCall();
        _burn(owner, tokens);
    }

    function _requireRouterSelfCall() private view {
        if (msg.sender != address(this)) {
            revert();
        }
    }

    function _delegateToFacet() private {
        address facet = _facet;
        // slither-disable-next-line assembly,low-level-calls
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _staticcallFacet() private view {
        address facet = _facet;
        // slither-disable-next-line assembly,low-level-calls
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := staticcall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
