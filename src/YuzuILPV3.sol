// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuILP} from "./YuzuILP.sol";
import {YuzuILPV2} from "./YuzuILPV2.sol";
import {YuzuV3FacetRouting} from "./YuzuV3FacetRouting.sol";
import {IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {IYuzuILPV3FacetPricing, IYuzuILPV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    MAX_MANAGEMENT_FEE_PPM,
    MAX_PERFORMANCE_FEE_PPM,
    PRICE_GUARD_MANAGER_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./libraries/YuzuV3Constants.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";
import {YuzuIssuer} from "./proto/YuzuIssuer.sol";
import {
    YuzuILPDistributionV3Storage,
    YuzuILPFeesV3Storage,
    YuzuMinAmountsV3Storage,
    YuzuThrottleV3Storage
} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuILPV3
 * @notice YuzuILP with V3 limits, throttles, pool guards, and fees
 */
contract YuzuILPV3 is YuzuILPV2, YuzuV3FacetRouting, IYuzuILPV3Definitions {
    // Construction and initialization
    constructor(address facet_) YuzuV3FacetRouting(facet_) {}

    /// @notice Initializes a fresh proxy directly at V3 with combined V1 and V3 setup
    /// @dev Guarded so it can only run before any prior init has set the asset
    // slither-disable-next-line pess-unprotected-initialize
    function initializeV3(InitParams calldata params, ConfigParams calldata config) external reinitializer(3) {
        if (_asset != address(0)) revert AlreadyInitialized();
        __YuzuProto_init(
            params.asset,
            params.name,
            params.symbol,
            params.admin,
            params.treasury,
            params.feeReceiver,
            params.supplyCap,
            params.fillWindow,
            params.minRedeemOrder
        );
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
        __YuzuILPV3_init_unchained();
        _applyConfig(config);
    }

    function _applyConfig(ConfigParams calldata config) internal {
        if (config.mintFeePpm > 1e6) revert FeeTooHigh(config.mintFeePpm, 1e6);
        if (config.redeemOrderFeePpm > 1e6) revert FeeTooHigh(config.redeemOrderFeePpm, 1e6);
        if (config.pendingManagementFeeRatePpm > MAX_MANAGEMENT_FEE_PPM) {
            revert FeeTooHigh(config.pendingManagementFeeRatePpm, MAX_MANAGEMENT_FEE_PPM);
        }
        if (config.pendingPerformanceFeeRatePpm > MAX_PERFORMANCE_FEE_PPM) {
            revert FeeTooHigh(config.pendingPerformanceFeeRatePpm, MAX_PERFORMANCE_FEE_PPM);
        }

        isMintRestricted = config.isMintRestricted;
        isRedeemRestricted = config.isRedeemRestricted;
        redeemOrderFeePpm = config.redeemOrderFeePpm;

        YuzuILPFeesV3Storage.Layout storage $ = YuzuILPFeesV3Storage.layout();
        $._mintFeePpm = config.mintFeePpm;
        $._pendingManagementFeeRatePpm = config.pendingManagementFeeRatePpm;
        $._pendingPerformanceFeeRatePpm = config.pendingPerformanceFeeRatePpm;

        // Mirror the setter events
        emit UpdatedIsMintRestricted(true, config.isMintRestricted);
        emit UpdatedIsRedeemRestricted(true, config.isRedeemRestricted);
        emit UpdatedRedeemOrderFee(0, config.redeemOrderFeePpm);
        emit UpdatedMintFee(0, config.mintFeePpm);
        emit UpdatedPendingManagementFee(0, config.pendingManagementFeeRatePpm);
        emit UpdatedPendingPerformanceFee(0, config.pendingPerformanceFeeRatePpm);
    }

    /// @notice Reinitializes an existing V1/V2 proxy for the V3 upgrade
    /// @dev Guarded so it can only run on a proxy that already went through prior init
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external override reinitializer(3) {
        if (_asset == address(0)) revert NotMigrating();
        __YuzuILPV3_init_unchained();
    }

    // slither-disable-next-line pess-unprotected-initialize
    function __YuzuILPV3_init_unchained() internal onlyInitializing {
        __YuzuProtoV2_init_unchained();
        __EIP712_init(name(), "2");
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PRICE_GUARD_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(DISTRIBUTOR_ROLE, ADMIN_ROLE);
        YuzuThrottleV3Storage.Layout storage $ = YuzuThrottleV3Storage.layout();
        $._mintThrottle.blockLimit = type(uint256).max;
        $._mintThrottle.dailyLimit = type(uint256).max;
        $._redeemThrottle.blockLimit = type(uint256).max;
        $._redeemThrottle.dailyLimit = type(uint256).max;
        YuzuILPDistributionV3Storage.layout()._minDistributionPeriod = 1 days;
    }

    // Disabled entrypoints
    /// @dev V3 proxies initialize via initializeV3 (fresh) or reinitialize (migration); the inherited
    /// V1 initializer is disabled so a stray proxy cannot be set up with V1 semantics.
    // slither-disable-next-line pess-unprotected-initialize
    function initialize(address, string memory, string memory, address, address, address, uint256, uint256, uint256)
        external
        pure
        override
    {
        revert InitializationDisabled();
    }

    // Facet routes: user actions
    function deposit(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function mint(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function burn(uint256) public virtual override {
        _delegateToFacet();
    }

    function fillRedeemOrder(uint256) public virtual override {
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

    // Facet routes: order lifecycle
    /// @dev Routed so the quote and the fill settlement derive from the facet's single valuation.
    function previewRedeemOrder(uint256) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    function createRedeemOrder(uint256, address, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function createRedeemOrderWithMaxFee(uint256, address, address, uint256)
        external
        virtual
        override
        returns (uint256)
    {
        _delegateToFacet();
    }

    function finalizeRedeemOrder(uint256) public virtual override {
        _delegateToFacet();
    }

    function cancelRedeemOrder(uint256) public virtual override {
        _delegateToFacet();
    }

    // Facet routes: pool operations
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

    // Facet routes: admin and config

    function setMinRedeemOrder(uint256) external virtual override {
        _delegateToFacet();
    }

    function setIsMintRestricted(bool) external virtual override {
        _delegateToFacet();
    }

    function setIsRedeemRestricted(bool) external virtual override {
        _delegateToFacet();
    }

    function setMintThrottle(uint256, uint256) external virtual {
        _delegateToFacet();
    }

    function setMinDeposit(uint256) external virtual {
        _delegateToFacet();
    }

    function setMintFee(uint256) external virtual {
        _delegateToFacet();
    }

    function setRedeemFee(uint256) external virtual override {
        _delegateToFacet();
    }

    function setRedeemOrderFee(uint256) external virtual override {
        _delegateToFacet();
    }

    /// @dev Stages the rate for the next pool update.
    function setPendingManagementFee(uint256) external virtual {
        _delegateToFacet();
    }

    /// @dev Stages the rate for the next pool update.
    function setPendingPerformanceFee(uint256) external virtual {
        _delegateToFacet();
    }

    function setMinDistributionPeriod(uint256) external virtual {
        _delegateToFacet();
    }

    // Native views
    function minDeposit() public view returns (uint256) {
        return YuzuMinAmountsV3Storage.layout()._minDeposit;
    }

    /// @notice Minimum permitted period for a new distribution
    function minDistributionPeriod() public view returns (uint256) {
        return YuzuILPDistributionV3Storage.layout()._minDistributionPeriod;
    }

    function getMintThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._mintThrottle;
    }

    /// @notice Deposit/mint fee in ppm of assets in
    function mintFeePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._mintFeePpm;
    }

    /// @notice Active management fee in ppm per year
    function managementFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._managementFeeRatePpm;
    }

    /// @notice Management fee staged for the next pool update
    function pendingManagementFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._pendingManagementFeeRatePpm;
    }

    /// @notice Total management fees withheld from holders
    function cumulativeManagementFees() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._cumulativeManagementFees;
    }

    /// @notice Active performance fee in ppm
    function performanceFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._performanceFeeRatePpm;
    }

    /// @notice Performance fee staged for the next pool update
    function pendingPerformanceFeeRatePpm() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._pendingPerformanceFeeRatePpm;
    }

    /// @notice Highest net-of-management share price reached
    function highWaterMark() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._highWaterMark;
    }

    /// @notice Total performance fees withheld from holders
    function cumulativePerformanceFees() public view returns (uint256) {
        return YuzuILPFeesV3Storage.layout()._cumulativePerformanceFees;
    }

    /// @notice Preview tokens minted for {assets}, net of the mint fee
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = YuzuV3Fees.feeOnTotal(assets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
        return super.previewDeposit(assets - fee);
    }

    /// @notice Preview assets paid to mint {tokens}, including the mint fee
    function previewMint(uint256 tokens) public view virtual override returns (uint256) {
        uint256 netAssets = super.previewMint(tokens);
        return netAssets + YuzuV3Fees.feeOnRaw(netAssets, YuzuILPFeesV3Storage.layout()._mintFeePpm);
    }

    // Internal overrides
    /// @dev The facet credits poolSize with the deposit's fee-adjusted value before routing here, so
    /// only the base transfer-and-mint runs.
    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens)
        internal
        virtual
        override(YuzuILPV2)
    {
        YuzuIssuer._deposit(caller, receiver, assets, tokens);
    }

    function _totalAssets(Math.Rounding rounding) internal view override(YuzuILPV2) returns (uint256) {
        return IYuzuILPV3FacetPricing(_facet).totalAssetsWithRounding(uint256(rounding));
    }

    /// @dev Replaces the inherited poolSize == 0 fresh-vault sentinel
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override(YuzuIssuer, YuzuILP)
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets * 10 ** _decimalsOffset();
        }
        uint256 totalAssets_ = _totalAssets(Math.Rounding(1 - uint256(rounding)));
        if (totalAssets_ == 0) {
            return 0;
        }
        return Math.mulDiv(supply, assets, totalAssets_, rounding);
    }

    // Router callbacks
    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external {
        _requireRouterSelfCall();
        _deposit(caller, receiver, assets, tokens);
    }

    function __routerBurn(address _owner, uint256 tokens) external {
        _requireRouterSelfCall();
        _burn(_owner, tokens);
    }

    function __routerTransfer(address from, address to, uint256 value) external {
        _requireRouterSelfCall();
        _transfer(from, to, value);
    }

    function __routerSpendAllowance(address _owner, address spender, uint256 value) external {
        _requireRouterSelfCall();
        _spendAllowance(_owner, spender, value);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
