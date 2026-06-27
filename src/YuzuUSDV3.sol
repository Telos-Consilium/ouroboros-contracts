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

/**
 * @title YuzuUSDV3
 * @notice YuzuUSD with minimum mint/redeem amounts, per-block/daily throttling, a same-block
 * mint+redeem guard on the instant paths, and an admin-set backing value that can mark the token
 * down below par
 * @dev The throttle and same-block guard gate only the instant deposit/mint and withdraw/redeem paths.
 * The order path (createRedeemOrder) is not gated. THROTTLE_EXEMPT_ROLE holders bypass both. Prices
 * settle at the backing value capped at par, so a value above par leaves payouts at par; minting is
 * disabled while the value is below par.
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

    /// @notice Par backing of one share, in the same scale as {nav}
    uint256 internal constant NAV_PRECISION = 1e18;
    uint256 private constant NAV_SHARE_SCALE = 1e30;

    uint256 internal constant DEFAULT_NAV_STEP_CAP_PPM = 100_000;
    uint256 internal constant DEFAULT_NAV_COOLDOWN = 1 days;

    struct YuzuMinAmountsStorage {
        uint256 _minDeposit;
        uint256 _minWithdraw;
    }

    struct YuzuThrottleStorage {
        Throttle _mintThrottle;
        Throttle _redeemThrottle;
    }

    struct YuzuSameBlockGuardStorage {
        mapping(address => uint256) _lastMintBlock;
    }

    struct YuzuNavMarkdownStorage {
        uint256 _nav;
        uint256 _stepCapPpm;
        uint256 _cooldown;
        uint256 _lastUpdate;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.minamounts")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuMinAmountsStorageLocation =
        0x3bac632b84cdc99ee809c17a81d1c3af6c49d197442158c702def7699ae31b00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.throttle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuThrottleStorageLocation =
        0x0b7c362ff29744eee18a40453a4b4ef5d7bd130da15027ce5dd041799a288e00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.sameblockguard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuSameBlockGuardStorageLocation =
        0xaca45614502cdf54c71f9031d97993837104eaf27a6531196fcefc0ea3a7a400;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.navmarkdown")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuNavMarkdownStorageLocation =
        0xbba33777aee3e8d94c5925677a78afa5780f0b9cf6f4464b380525cccd6c9300;

    address private immutable _featureFacet;

    constructor(address featureFacet_) {
        if (featureFacet_ == address(0)) {
            revert InvalidZeroAddress();
        }
        _featureFacet = featureFacet_;
    }

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(NAV_MANAGER_ROLE, ADMIN_ROLE);
        YuzuThrottleStorage storage throttleStorage = _getYuzuThrottleStorage();
        Throttle storage mintThrottle_ = throttleStorage._mintThrottle;
        mintThrottle_.blockLimit = type(uint256).max;
        mintThrottle_.dailyLimit = type(uint256).max;

        Throttle storage redeemThrottle_ = throttleStorage._redeemThrottle;
        redeemThrottle_.blockLimit = type(uint256).max;
        redeemThrottle_.dailyLimit = type(uint256).max;

        YuzuNavMarkdownStorage storage navStorage = _getYuzuNavMarkdownStorage();
        navStorage._nav = NAV_PRECISION;
        navStorage._stepCapPpm = DEFAULT_NAV_STEP_CAP_PPM;
        navStorage._cooldown = DEFAULT_NAV_COOLDOWN;
    }

    /// @dev THROTTLE_EXEMPT_ROLE keys on the owner or receiver in both the views and the
    /// state-changing paths, the standard ERC-4626 principal. Caller-keying is reserved for
    /// vaults whose integration model is caller-keyed; the proto vaults have none.
    function _isThrottleExempt(address account) private view returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256, uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemThrottle(uint256, uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinWithdraw(uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNav(uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNavStepCap(uint256) external virtual {
        _delegateToFeatureFacet();
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNavCooldown(uint256) external virtual {
        _delegateToFeatureFacet();
    }

    /// @notice Returns the mint throttle limits and usage
    function getMintThrottle() external view returns (Throttle memory) {
        return _getYuzuThrottleStorage()._mintThrottle;
    }

    /// @notice Returns the redeem throttle limits and usage
    function getRedeemThrottle() external view returns (Throttle memory) {
        return _getYuzuThrottleStorage()._redeemThrottle;
    }

    function minDeposit() public view returns (uint256) {
        return _getYuzuMinAmountsStorage()._minDeposit;
    }

    function minWithdraw() public view returns (uint256) {
        return _getYuzuMinAmountsStorage()._minWithdraw;
    }

    function lastMintBlock(address account) external view returns (uint256) {
        return _getYuzuSameBlockGuardStorage()._lastMintBlock[account];
    }

    /// @notice Backing value of one share, scaled so {NAV_PRECISION} is par
    function nav() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._nav;
    }

    /// @notice Maximum relative change per nav update, in ppm of the current nav
    function navStepCapPpm() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._stepCapPpm;
    }

    /// @notice Minimum seconds between nav updates
    function navCooldown() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._cooldown;
    }

    /// @notice Timestamp of the last nav update
    function navLastUpdate() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._lastUpdate;
    }

    /// @notice Whether the token is marked down, i.e. nav is below par
    function isMarkedDown() public view returns (bool) {
        return _getYuzuNavMarkdownStorage()._nav < NAV_PRECISION;
    }

    function maxDeposit(address) public view virtual override returns (uint256) {
        _delegateToFeatureFacetView();
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (proto share price is not bounded below 1).
    function maxMint(address) public view virtual override returns (uint256) {
        _delegateToFeatureFacetView();
    }

    /// @dev Reported net of the fee; throttle capacity is denominated in gross outflow
    function maxWithdraw(address) public view virtual override returns (uint256) {
        _delegateToFeatureFacetView();
    }

    function maxRedeem(address) public view virtual override returns (uint256) {
        _delegateToFeatureFacetView();
    }

    function deposit(uint256, address) public virtual override returns (uint256) {
        _delegateToFeatureFacet();
    }

    function mint(uint256, address) public virtual override returns (uint256) {
        _delegateToFeatureFacet();
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        _delegateToFeatureFacet();
    }

    function redeem(uint256, address, address) public virtual override returns (uint256) {
        _delegateToFeatureFacet();
    }

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

    function _requireMintEnabled() internal view {
        uint256 currentNav = nav();
        if (currentNav < NAV_PRECISION) {
            revert MintDisabledWhileMarkedDown(currentNav);
        }
    }

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

    function _requireRouterSelfCall() private view {
        if (msg.sender != address(this)) {
            revert();
        }
    }

    function _effectiveNav() private view returns (uint256) {
        return Math.min(_getYuzuNavMarkdownStorage()._nav, NAV_PRECISION);
    }

    function _checkMinDeposit(uint256 assets) private view {
        uint256 min = minDeposit();
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = minWithdraw();
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    function _delegateToFeatureFacet() private {
        address facet = _featureFacet;
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

    function _delegateToFeatureFacetView() private view {
        address facet = _featureFacet;
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

    function _getYuzuMinAmountsStorage() private pure returns (YuzuMinAmountsStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuMinAmountsStorageLocation
        }
    }

    function _getYuzuThrottleStorage() private pure returns (YuzuThrottleStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuThrottleStorageLocation
        }
    }

    function _getYuzuSameBlockGuardStorage() private pure returns (YuzuSameBlockGuardStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuSameBlockGuardStorageLocation
        }
    }

    function _getYuzuNavMarkdownStorage() private pure returns (YuzuNavMarkdownStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuNavMarkdownStorageLocation
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
