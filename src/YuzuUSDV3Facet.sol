// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuIssuerDefinitions} from "./interfaces/proto/IYuzuIssuerDefinitions.sol";
import {
    IYuzuMinAmountsDefinitions,
    IYuzuNavMarkdownDefinitions,
    IYuzuSameBlockGuardDefinitions
} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuUSDV3Router} from "./interfaces/IYuzuV3FacetRouters.sol";
import {IYuzuThrottleDefinitions, Throttle} from "./interfaces/proto/IYuzuThrottleDefinitions.sol";

/**
 * @title YuzuUSDV3Facet
 */
contract YuzuUSDV3Facet is
    IYuzuIssuerDefinitions,
    IYuzuMinAmountsDefinitions,
    IYuzuThrottleDefinitions,
    IYuzuNavMarkdownDefinitions,
    IYuzuSameBlockGuardDefinitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    uint256 internal constant NAV_PRECISION = 1e18;

    struct YuzuMinAmountsStorage {
        uint256 _minDeposit;
        uint256 _minWithdraw;
    }

    struct YuzuThrottleStorage {
        Throttle _mintThrottle;
        Throttle _redeemThrottle;
    }

    struct YuzuNavMarkdownStorage {
        uint256 _nav;
        uint256 _stepCapPpm;
        uint256 _cooldown;
        uint256 _lastUpdate;
    }

    struct YuzuSameBlockGuardStorage {
        mapping(address => uint256) _lastMintBlock;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.minamounts")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuMinAmountsStorageLocation =
        0x3bac632b84cdc99ee809c17a81d1c3af6c49d197442158c702def7699ae31b00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.throttle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuThrottleStorageLocation =
        0x0b7c362ff29744eee18a40453a4b4ef5d7bd130da15027ce5dd041799a288e00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.navmarkdown")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuNavMarkdownStorageLocation =
        0xbba33777aee3e8d94c5925677a78afa5780f0b9cf6f4464b380525cccd6c9300;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.sameblockguard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuSameBlockGuardStorageLocation =
        0xaca45614502cdf54c71f9031d97993837104eaf27a6531196fcefc0ea3a7a400;

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        _requireMintEnabled();
        _checkMinDeposit(assets);
        uint256 maxAssets = _maxDeposit(address(this), receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 tokens = IYuzuUSDV3Router(address(this)).previewDeposit(assets);
        IYuzuUSDV3Router(address(this)).__routerDeposit(msg.sender, receiver, assets, tokens);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver, tokens);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) external returns (uint256) {
        _requireMintEnabled();
        uint256 assets = IYuzuUSDV3Router(address(this)).previewMint(tokens);
        _checkMinDeposit(assets);
        uint256 maxTokens = _maxMint(address(this), receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }
        IYuzuUSDV3Router(address(this)).__routerDeposit(msg.sender, receiver, assets, tokens);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver, tokens);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(owner);
        uint256 maxAssets = _maxWithdraw(address(this), owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        uint256 tokens = IYuzuUSDV3Router(address(this)).previewWithdraw(assets);
        uint256 fee = _feeOnRaw(assets, IYuzuUSDV3Router(address(this)).redeemFeePpm());
        IYuzuUSDV3Router(address(this)).__routerWithdraw(msg.sender, receiver, owner, assets, tokens, fee);
        _consumeRedeemThrottle(owner, assets + fee);
        return tokens;
    }

    function redeem(uint256 tokens, address receiver, address owner) external returns (uint256) {
        uint256 maxTokens = _maxRedeem(address(this), owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(owner, tokens, maxTokens);
        }
        uint256 grossAssets = IYuzuUSDV3Router(address(this)).convertToAssets(tokens);
        uint256 fee = _feeOnTotal(grossAssets, IYuzuUSDV3Router(address(this)).redeemFeePpm());
        uint256 assets = grossAssets - fee;
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(owner);
        IYuzuUSDV3Router(address(this)).__routerWithdraw(msg.sender, receiver, owner, assets, tokens, fee);
        _consumeRedeemThrottle(owner, assets + fee);
        return assets;
    }

    function maxDeposit(address receiver) public view returns (uint256) {
        return _maxDeposit(msg.sender, receiver);
    }

    function maxMint(address receiver) public view returns (uint256) {
        return _maxMint(msg.sender, receiver);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        return _maxWithdraw(msg.sender, owner);
    }

    function maxRedeem(address owner) public view returns (uint256) {
        return _maxRedeem(msg.sender, owner);
    }

    function _maxDeposit(address proxy, address receiver) private view returns (uint256) {
        if (_isMarkedDown(proxy) || !_canMint(proxy, receiver)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 baseMax = IYuzuUSDV3Router(proxy).convertToAssets(headroom);
        uint256 maxAssets = Math.min(baseMax, _mintThrottleRemaining(proxy, receiver));
        uint256 min = IYuzuUSDV3Router(proxy).minDeposit();
        return maxAssets < min ? 0 : maxAssets;
    }

    function _maxMint(address proxy, address receiver) private view returns (uint256) {
        if (_isMarkedDown(proxy) || !_canMint(proxy, receiver)) {
            return 0;
        }
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 remaining = _mintThrottleRemaining(proxy, receiver);
        uint256 shares = remaining >= type(uint128).max
            ? headroom
            : Math.min(headroom, IYuzuUSDV3Router(proxy).convertToShares(remaining));
        uint256 min = IYuzuUSDV3Router(proxy).minDeposit();
        return IYuzuUSDV3Router(proxy).previewMint(shares) < min ? 0 : shares;
    }

    function _maxWithdraw(address proxy, address owner) private view returns (uint256) {
        if (!_canRedeem(proxy, owner)) {
            return 0;
        }
        uint256 feePpm = IYuzuUSDV3Router(proxy).redeemFeePpm();
        uint256 liquid = IYuzuUSDV3Router(proxy).liquidityBufferSize();
        uint256 fee = _feeOnTotal(liquid, feePpm);
        uint256 baseMax =
            Math.min(IYuzuUSDV3Router(proxy).previewRedeem(IYuzuUSDV3Router(proxy).balanceOf(owner)), liquid - fee);
        uint256 remaining = _redeemThrottleRemaining(proxy, owner);
        uint256 throttleMax = remaining - _feeOnTotal(remaining, feePpm);
        uint256 maxAssets = Math.min(baseMax, throttleMax);
        uint256 min = IYuzuUSDV3Router(proxy).minWithdraw();
        return maxAssets < min ? 0 : maxAssets;
    }

    function _maxRedeem(address proxy, address owner) private view returns (uint256) {
        if (!_canRedeem(proxy, owner)) {
            return 0;
        }
        uint256 maxTokens = Math.min(
            IYuzuUSDV3Router(proxy).convertToShares(IYuzuUSDV3Router(proxy).liquidityBufferSize()),
            IYuzuUSDV3Router(proxy).balanceOf(owner)
        );
        uint256 remaining = _redeemThrottleRemaining(proxy, owner);
        uint256 shares = IYuzuUSDV3Router(proxy).convertToAssets(maxTokens) <= remaining
            ? maxTokens
            : IYuzuUSDV3Router(proxy).convertToShares(remaining);
        uint256 min = IYuzuUSDV3Router(proxy).minWithdraw();
        return IYuzuUSDV3Router(proxy).previewRedeem(shares) < min ? 0 : shares;
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = _getYuzuThrottleStorage()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = _getYuzuThrottleStorage()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsStorage storage $ = _getYuzuMinAmountsStorage();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinWithdraw(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsStorage storage $ = _getYuzuMinAmountsStorage();
        uint256 oldMin = $._minWithdraw;
        $._minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNav(uint256 newNav) external {
        _checkRole(NAV_MANAGER_ROLE);
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 currentNav = $._nav;

        uint256 lastUpdate = $._lastUpdate;
        if (lastUpdate != 0) {
            uint256 readyAt = lastUpdate + $._cooldown;
            if (block.timestamp < readyAt) {
                revert NavCooldownActive(block.timestamp, readyAt);
            }
        }

        uint256 maxDelta = Math.mulDiv(currentNav, $._stepCapPpm, 1e6);
        uint256 delta = newNav > currentNav ? newNav - currentNav : currentNav - newNav;
        if (delta > maxDelta) {
            revert NavStepTooLarge(newNav, currentNav, maxDelta);
        }

        $._nav = newNav;
        $._lastUpdate = block.timestamp;
        emit UpdatedNav(currentNav, newNav);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNavStepCap(uint256 newStepCapPpm) external {
        _checkRole(ADMIN_ROLE);
        if (newStepCapPpm > 1e6) {
            revert InvalidNavStepCap(newStepCapPpm, 1e6);
        }
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 oldStepCapPpm = $._stepCapPpm;
        $._stepCapPpm = newStepCapPpm;
        emit UpdatedNavStepCap(oldStepCapPpm, newStepCapPpm);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNavCooldown(uint256 newCooldown) external {
        _checkRole(ADMIN_ROLE);
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 oldCooldown = $._cooldown;
        $._cooldown = newCooldown;
        emit UpdatedNavCooldown(oldCooldown, newCooldown);
    }

    function _checkRole(bytes32 role) private view {
        if (!IAccessControl(address(this)).hasRole(role, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, role);
        }
    }

    function _isThrottleExempt(address account) private view returns (bool) {
        return IAccessControl(address(this)).hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _canMint(address proxy, address receiver) private view returns (bool) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        return !router.paused() && (!router.isMintRestricted() || IAccessControl(proxy).hasRole(MINTER_ROLE, receiver));
    }

    function _canRedeem(address proxy, address owner) private view returns (bool) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        return !router.paused() && (!router.isRedeemRestricted() || IAccessControl(proxy).hasRole(REDEEMER_ROLE, owner));
    }

    function _isMarkedDown(address proxy) private view returns (bool) {
        return IYuzuUSDV3Router(proxy).nav() < NAV_PRECISION;
    }

    function _supplyHeadroom(address proxy) private view returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        uint256 supplyCap = router.cap();
        uint256 supply = router.totalSupply();
        return supply >= supplyCap ? 0 : supplyCap - supply;
    }

    function _mintThrottleRemaining(address proxy, address account) private view returns (uint256) {
        if (IAccessControl(proxy).hasRole(THROTTLE_EXEMPT_ROLE, account)) {
            return type(uint256).max;
        }
        Throttle memory throttle = IYuzuUSDV3Router(proxy).getMintThrottle();
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(throttle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _redeemThrottleRemaining(address proxy, address account) private view returns (uint256) {
        if (IAccessControl(proxy).hasRole(THROTTLE_EXEMPT_ROLE, account)) {
            return type(uint256).max;
        }
        Throttle memory throttle = IYuzuUSDV3Router(proxy).getRedeemThrottle();
        (uint256 blockRemaining, uint256 dailyRemaining) = _remaining(throttle);
        return Math.min(blockRemaining, dailyRemaining);
    }

    function _requireMintEnabled() private view {
        uint256 currentNav = _getYuzuNavMarkdownStorage()._nav;
        if (currentNav < NAV_PRECISION) {
            revert MintDisabledWhileMarkedDown(currentNav);
        }
    }

    function _checkMinDeposit(uint256 assets) private view {
        uint256 min = _getYuzuMinAmountsStorage()._minDeposit;
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = _getYuzuMinAmountsStorage()._minWithdraw;
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    function _consumeMintThrottle(address account, uint256 assets) private {
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

    function _consumeRedeemThrottle(address account, uint256 assets) private {
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

    function _recordMintBlock(address receiver, uint256 amount) private {
        if (amount == 0 || _isThrottleExempt(receiver)) {
            return;
        }
        _getYuzuSameBlockGuardStorage()._lastMintBlock[receiver] = block.number;
    }

    function _checkSameBlockRedeem(address owner) private view {
        if (_isThrottleExempt(owner)) {
            return;
        }
        if (_getYuzuSameBlockGuardStorage()._lastMintBlock[owner] == block.number) {
            revert SameBlockMintRedeem(owner);
        }
    }

    function _remaining(Throttle memory throttle)
        private
        view
        returns (uint256 blockRemaining, uint256 dailyRemaining)
    {
        uint256 blockLimit = throttle.blockLimit;
        uint256 usedInBlock = throttle.lastBlock == block.number ? throttle.usedInBlock : 0;
        blockRemaining = usedInBlock >= blockLimit ? 0 : blockLimit - usedInBlock;

        uint256 dailyLimit = throttle.dailyLimit;
        uint256 usedInDay = throttle.lastDay == _currentDay() ? throttle.usedInDay : 0;
        dailyRemaining = usedInDay >= dailyLimit ? 0 : dailyLimit - usedInDay;
    }

    function _consume(Throttle storage throttle, uint256 assets) private {
        throttle.usedInBlock = (throttle.lastBlock == block.number ? throttle.usedInBlock : 0) + assets;
        throttle.lastBlock = block.number;

        uint256 day = _currentDay();
        throttle.usedInDay = (throttle.lastDay == day ? throttle.usedInDay : 0) + assets;
        throttle.lastDay = day;
    }

    function _feeOnRaw(uint256 assets, uint256 feePpm) private pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    function _feeOnTotal(uint256 assets, uint256 feePpm) private pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    function _currentDay() private view returns (uint256) {
        return block.timestamp / 1 days;
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

    function _getYuzuNavMarkdownStorage() private pure returns (YuzuNavMarkdownStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuNavMarkdownStorageLocation
        }
    }

    function _getYuzuSameBlockGuardStorage() private pure returns (YuzuSameBlockGuardStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuSameBlockGuardStorageLocation
        }
    }
}
