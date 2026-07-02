// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YuzuIssuer} from "./proto/YuzuIssuer.sol";
import {YuzuUSD} from "./YuzuUSD.sol";
import {YuzuUSDV2} from "./YuzuUSDV2.sol";
import {
    IYuzuMinAmountsDefinitions,
    IYuzuNavMarkdownDefinitions,
    IYuzuSameBlockGuardDefinitions
} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";
import {
    YuzuMinAmountsV3Storage,
    YuzuNavMarkdownV3Storage,
    YuzuSameBlockGuardV3Storage,
    YuzuThrottleV3Storage
} from "./storage/YuzuV3Storage.sol";

/**
 * @title YuzuUSDV3
 * @notice YuzuUSD with V3 limits, throttles, same-block guard, and NAV markdowns
 * @dev Throttles and same-block checks apply only to instant paths. Order redemptions use minWithdraw
 * at creation and settle at the backing value capped at par.
 */
contract YuzuUSDV3 is
    YuzuUSDV2,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions,
    IYuzuSameBlockGuardDefinitions,
    IYuzuNavMarkdownDefinitions
{
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 internal constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");

    /// @notice Par backing of one share, in the same scale as nav
    uint256 internal constant NAV_PRECISION = 1e18;
    uint256 private constant NAV_SHARE_SCALE = 1e30;

    uint256 internal constant DEFAULT_NAV_STEP_CAP_PPM = 100_000;
    uint256 internal constant DEFAULT_NAV_COOLDOWN = 1 days;

    address private immutable _facet;

    // Construction
    constructor(address facet_) {
        if (facet_ == address(0)) {
            revert InvalidZeroAddress();
        }
        _facet = facet_;
    }

    // V3 init
    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external override reinitializer(3) {
        __YuzuProtoV2_init_unchained();
        __EIP712_init(name(), "2");
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(NAV_MANAGER_ROLE, ADMIN_ROLE);
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

    // V3 config routes
    // slither-disable-next-line pess-event-setter
    function setMintThrottle(uint256, uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setRedeemThrottle(uint256, uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setMinDeposit(uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setMinWithdraw(uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setNav(uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setNavStepCap(uint256) external virtual {
        _delegateToFacet();
    }

    // slither-disable-next-line pess-event-setter
    function setNavCooldown(uint256) external virtual {
        _delegateToFacet();
    }

    // V3 views
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

    function lastMintBlock(address account) external view returns (uint256) {
        return YuzuSameBlockGuardV3Storage.layout()._lastMintBlock[account];
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

    // ERC4626 view routes
    function maxDeposit(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (proto share price is not bounded below 1).
    function maxMint(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    /// @dev Reported net of the fee; throttle capacity is denominated in gross outflow
    function maxWithdraw(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    function maxRedeem(address) public view virtual override returns (uint256) {
        _staticcallFacet();
    }

    // ERC4626 write routes
    function deposit(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function mint(uint256, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    function redeem(uint256, address, address) public virtual override returns (uint256) {
        _delegateToFacet();
    }

    // Order path
    function _createRedeemOrder(address caller, address receiver, address owner, uint256 tokens)
        internal
        virtual
        override
        returns (uint256)
    {
        uint256 assets = previewRedeemOrder(tokens);
        uint256 min = minWithdraw();
        if (assets < min) revert UnderMinWithdraw(assets, min);
        return super._createRedeemOrder(caller, receiver, owner, tokens);
    }

    // Conversion hooks
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

    // Router callbacks
    function __routerDeposit(address caller, address receiver, uint256 assets, uint256 tokens) external {
        _requireRouterSelfCall();
        _deposit(caller, receiver, assets, tokens);
    }

    function __routerWithdraw(
        address caller,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 tokens,
        uint256 fee
    ) external {
        _requireRouterSelfCall();
        _withdraw(caller, receiver, _owner, assets, tokens, fee);
    }

    // Router helpers
    function _requireRouterSelfCall() private view {
        if (msg.sender != address(this)) {
            revert();
        }
    }

    function _effectiveNav() private view returns (uint256) {
        return Math.min(YuzuNavMarkdownV3Storage.layout()._nav, NAV_PRECISION);
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
    uint256[50] private __gap;
}
