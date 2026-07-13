// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    FEE_MANAGER_ROLE,
    MARKDOWN_STEP_EXEMPT_ROLE,
    NAV_MANAGER_ROLE,
    PRICE_GUARD_MANAGER_ROLE,
    SAME_BLOCK_EXEMPT_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./libraries/YuzuV3Constants.sol";
import {YuzuV3RestrictedShares} from "./libraries/YuzuV3RestrictedShares.sol";
import {YuzuV3Throttle} from "./libraries/YuzuV3Throttle.sol";
import {YuzuIssuer} from "./proto/YuzuIssuer.sol";
import {YuzuUSD} from "./YuzuUSD.sol";
import {YuzuUSDV2} from "./YuzuUSDV2.sol";
import {YuzuV3FacetRouting} from "./YuzuV3FacetRouting.sol";
import {IYuzuMinAmountsDefinitions, IYuzuNavMarkdownDefinitions} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {YuzuMinAmountsV3Storage, YuzuNavMarkdownV3Storage, YuzuThrottleV3Storage} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuUSDV3
 * @notice YuzuUSD with V3 limits, throttles, same-block guard, and NAV markdowns
 * @dev Throttles and the same-block guard apply only to the instant paths, not the order path.
 */
// slither-disable-next-line missing-inheritance
contract YuzuUSDV3 is
    YuzuUSDV2,
    YuzuV3FacetRouting,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions,
    IYuzuNavMarkdownDefinitions
{
    /// @notice Par backing of one share, in the same scale as nav
    uint256 internal constant NAV_PRECISION = 1e18;
    uint256 private constant NAV_SHARE_SCALE = 1e30;

    uint256 internal constant DEFAULT_NAV_STEP_CAP_PPM = 100_000;
    uint256 internal constant DEFAULT_NAV_COOLDOWN = 1 days;

    // Construction and initialization
    constructor(address facet_) YuzuV3FacetRouting(facet_) {}

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external override reinitializer(3) {
        __YuzuProtoV2_init_unchained();
        __EIP712_init(name(), "2");
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SAME_BLOCK_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(NAV_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(MARKDOWN_STEP_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PRICE_GUARD_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        YuzuThrottleV3Storage.Layout storage throttleStorage = YuzuThrottleV3Storage.layout();
        Throttle storage mintThrottle_ = throttleStorage._mintThrottle;
        mintThrottle_.blockLimit = type(uint256).max;
        mintThrottle_.dailyLimit = type(uint256).max;

        Throttle storage redeemThrottle_ = throttleStorage._redeemThrottle;
        redeemThrottle_.blockLimit = type(uint256).max;
        redeemThrottle_.dailyLimit = type(uint256).max;

        YuzuNavMarkdownV3Storage.Layout storage navStorage = YuzuNavMarkdownV3Storage.layout();
        navStorage._nav = NAV_PRECISION;
        navStorage._stepCapPpm = DEFAULT_NAV_STEP_CAP_PPM;
        navStorage._cooldown = DEFAULT_NAV_COOLDOWN;
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

    function fillRedeemOrder(uint256) public virtual override {
        _delegateToFacet();
    }

    function finalizeRedeemOrder(uint256) public virtual override {
        _delegateToFacet();
    }

    function cancelRedeemOrder(uint256) public virtual override {
        _delegateToFacet();
    }

    // Facet routes: admin and config
    function setMinRedeemOrder(uint256) external virtual override {
        _delegateToFacet();
    }

    function setRedeemFee(uint256) external virtual override {
        _delegateToFacet();
    }

    function setRedeemOrderFee(uint256) external virtual override {
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

    function setRedeemThrottle(uint256, uint256) external virtual {
        _delegateToFacet();
    }

    function setMinDeposit(uint256) external virtual {
        _delegateToFacet();
    }

    function setMinWithdraw(uint256) external virtual {
        _delegateToFacet();
    }

    function setNav(uint256) external virtual {
        _delegateToFacet();
    }

    function setNavStepCap(uint256) external virtual {
        _delegateToFacet();
    }

    function setNavCooldown(uint256) external virtual {
        _delegateToFacet();
    }

    // Native views
    /// @notice Returns the mint throttle limits and usage
    function getMintThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._mintThrottle;
    }

    /// @notice Returns the redeem throttle limits and usage
    function getRedeemThrottle() external view returns (Throttle memory) {
        return YuzuThrottleV3Storage.layout()._redeemThrottle;
    }

    function minDeposit() public view returns (uint256) {
        return YuzuMinAmountsV3Storage.layout()._minDeposit;
    }

    function minWithdraw() public view returns (uint256) {
        return YuzuMinAmountsV3Storage.layout()._minWithdraw;
    }

    /// @notice Shares received this block and excluded from instant redemption unless the owner has SAME_BLOCK_EXEMPT_ROLE
    function currentBlockRestrictedBalance(address account) external view returns (uint256) {
        return YuzuV3RestrictedShares.currentBlockRestrictedBalance(account);
    }

    /// @notice Backing value of one share; NAV_PRECISION is par
    function nav() public view returns (uint256) {
        return YuzuNavMarkdownV3Storage.layout()._nav;
    }

    /// @notice Maximum relative change per nav update, in ppm of the current nav
    function navStepCapPpm() public view returns (uint256) {
        return YuzuNavMarkdownV3Storage.layout()._stepCapPpm;
    }

    /// @notice Minimum seconds between nav updates
    function navCooldown() public view returns (uint256) {
        return YuzuNavMarkdownV3Storage.layout()._cooldown;
    }

    /// @notice Timestamp of the last nav update
    function navLastUpdate() public view returns (uint256) {
        return YuzuNavMarkdownV3Storage.layout()._lastUpdate;
    }

    /// @notice Whether nav is below par
    function isMarkedDown() public view returns (bool) {
        return YuzuNavMarkdownV3Storage.layout()._nav < NAV_PRECISION;
    }

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        uint256 baseMax = _convertToAssets(_supplyHeadroom(), Math.Rounding.Floor);
        uint256 maxAssets = Math.min(baseMax, _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (proto share price is not bounded below 1).
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom();
        uint256 remaining = _mintThrottleRemaining(receiver);
        uint256 shares = remaining >= type(uint128).max
            ? headroom
            : Math.min(headroom, _convertToShares(remaining, Math.Rounding.Floor));
        return previewMint(shares) < minDeposit() ? 0 : shares;
    }

    /// @dev Reported net of the fee; throttle capacity is denominated in gross outflow
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        uint256 liquid = liquidityBufferSize();
        uint256 fee = _feeOnTotal(liquid, redeemFeePpm);
        (uint256 redeemable,) = _previewRedeem(_matureBalance(_owner));
        uint256 baseMax = Math.min(redeemable, liquid - fee);
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 throttleMax = remaining - _feeOnTotal(remaining, redeemFeePpm);
        uint256 maxAssets = Math.min(baseMax, throttleMax);
        return maxAssets < minWithdraw() ? 0 : maxAssets;
    }

    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        uint256 maxTokens =
            Math.min(_convertToShares(liquidityBufferSize(), Math.Rounding.Floor), _matureBalance(_owner));
        uint256 remaining = _redeemThrottleRemaining(_owner);
        uint256 shares = _convertToAssets(maxTokens, Math.Rounding.Floor) <= remaining
            ? maxTokens
            : _convertToShares(remaining, Math.Rounding.Floor);
        (uint256 previewed,) = _previewRedeem(shares);
        return previewed < minWithdraw() ? 0 : shares;
    }

    // Native flows
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 tokens = previewDeposit(assets);
        _consumeMintThrottle(receiver, assets);
        _deposit(_msgSender(), receiver, assets, tokens);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual override returns (uint256) {
        uint256 assets = previewMint(tokens);
        _checkMinDeposit(assets);
        uint256 maxTokens = maxMint(receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }
        _consumeMintThrottle(receiver, assets);
        _deposit(_msgSender(), receiver, assets, tokens);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(_owner, assets, maxAssets);
        }
        (uint256 tokens, uint256 fee) = _previewWithdraw(assets);
        _consumeRedeemThrottle(_owner, assets + fee);
        _withdraw(_msgSender(), receiver, _owner, assets, tokens, fee);
        return tokens;
    }

    function redeem(uint256 tokens, address receiver, address _owner) public virtual override returns (uint256) {
        uint256 maxTokens = maxRedeem(_owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(_owner, tokens, maxTokens);
        }
        (uint256 assets, uint256 fee) = _previewRedeem(tokens);
        _checkMinWithdraw(assets);
        _consumeRedeemThrottle(_owner, assets + fee);
        _withdraw(_msgSender(), receiver, _owner, assets, tokens, fee);
        return assets;
    }

    // Internal overrides
    /// @dev Folds the backing value (capped at par) into the par decimal scaling. At par this is the
    /// inherited 1:1 conversion; below par a share converts to fewer assets and an asset to more shares.
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        override(YuzuIssuer, YuzuUSD)
        returns (uint256)
    {
        return Math.mulDiv(assets, NAV_SHARE_SCALE, _effectiveNav(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        override(YuzuIssuer, YuzuUSD)
        returns (uint256)
    {
        return Math.mulDiv(shares, _effectiveNav(), NAV_SHARE_SCALE, rounding);
    }

    function _effectiveNav() private view returns (uint256) {
        return Math.min(YuzuNavMarkdownV3Storage.layout()._nav, NAV_PRECISION);
    }

    // Router callbacks
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

    // Limit and guard helpers
    function _supplyHeadroom() private view returns (uint256) {
        uint256 supplyCap = cap();
        uint256 supply = totalSupply();
        return supply >= supplyCap ? 0 : supplyCap - supply;
    }

    function _isThrottleExempt(address account) private view returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _mintThrottleRemaining(address account) private view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) =
            YuzuV3Throttle.remaining(YuzuThrottleV3Storage.layout()._mintThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _redeemThrottleRemaining(address account) private view returns (uint256) {
        if (_isThrottleExempt(account)) {
            return type(uint256).max;
        }
        (uint256 blockRemaining, uint256 dailyRemaining) =
            YuzuV3Throttle.remaining(YuzuThrottleV3Storage.layout()._redeemThrottle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _consumeMintThrottle(address account, uint256 assets) private {
        if (_isThrottleExempt(account)) {
            return;
        }
        YuzuV3Throttle.consumeMintChecked(YuzuThrottleV3Storage.layout()._mintThrottle, assets);
    }

    function _consumeRedeemThrottle(address account, uint256 assets) private {
        if (_isThrottleExempt(account)) {
            return;
        }
        YuzuV3Throttle.consumeRedeemChecked(YuzuThrottleV3Storage.layout()._redeemThrottle, assets);
    }

    function _isSameBlockExempt(address account) private view returns (bool) {
        return hasRole(SAME_BLOCK_EXEMPT_ROLE, account);
    }

    /// @dev Balance an owner can redeem this block; excludes shares received in the current block
    /// unless the owner is same-block exempt.
    function _matureBalance(address _owner) private view returns (uint256) {
        if (_isSameBlockExempt(_owner)) {
            return balanceOf(_owner);
        }
        return balanceOf(_owner) - YuzuV3RestrictedShares.currentBlockRestrictedBalance(_owner);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);
        YuzuV3RestrictedShares.update(from, to, value, balanceOf(from));
    }

    function _checkMinDeposit(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minDeposit;
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minWithdraw;
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
