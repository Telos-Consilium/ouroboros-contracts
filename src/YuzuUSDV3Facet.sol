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
import {
    YuzuMinAmountsV3Storage,
    YuzuNavMarkdownV3Storage,
    YuzuSameBlockGuardV3Storage,
    YuzuThrottleV3Storage
} from "./storage/YuzuV3Storage.sol";

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

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        _requireMintEnabled();
        _checkMinDeposit(assets);
        uint256 maxAssets = _maxDeposit(address(this), receiver);
        if (assets > maxAssets) {
            revert ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 tokens = router.previewDeposit(assets);
        router.__routerDeposit(msg.sender, receiver, assets, tokens);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver, tokens);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) external returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        _requireMintEnabled();
        uint256 assets = router.previewMint(tokens);
        _checkMinDeposit(assets);
        uint256 maxTokens = _maxMint(address(this), receiver);
        if (tokens > maxTokens) {
            revert ExceededMaxMint(receiver, tokens, maxTokens);
        }
        router.__routerDeposit(msg.sender, receiver, assets, tokens);
        _consumeMintThrottle(receiver, assets);
        _recordMintBlock(receiver, tokens);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(owner);
        uint256 maxAssets = _maxWithdraw(address(this), owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        uint256 tokens = router.previewWithdraw(assets);
        uint256 fee = _feeOnRaw(assets, router.redeemFeePpm());
        router.__routerWithdraw(msg.sender, receiver, owner, assets, tokens, fee);
        _consumeRedeemThrottle(owner, assets + fee);
        return tokens;
    }

    function withdrawWithSlippage(uint256 assets, address receiver, address owner, uint256 maxTokens)
        external
        returns (uint256)
    {
        uint256 tokens = withdraw(assets, receiver, owner);
        if (tokens > maxTokens) {
            revert RedeemedMoreThanMaxTokens(tokens, maxTokens);
        }
        return tokens;
    }

    function redeem(uint256 tokens, address receiver, address owner) public returns (uint256) {
        IYuzuUSDV3Router router = IYuzuUSDV3Router(address(this));
        uint256 maxTokens = _maxRedeem(address(this), owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeem(owner, tokens, maxTokens);
        }
        uint256 grossAssets = router.convertToAssets(tokens);
        uint256 fee = _feeOnTotal(grossAssets, router.redeemFeePpm());
        uint256 assets = grossAssets - fee;
        _checkMinWithdraw(assets);
        _checkSameBlockRedeem(owner);
        router.__routerWithdraw(msg.sender, receiver, owner, assets, tokens, fee);
        _consumeRedeemThrottle(owner, assets + fee);
        return assets;
    }

    function redeemWithSlippage(uint256 tokens, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256)
    {
        uint256 assets = redeem(tokens, receiver, owner);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
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

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedMintThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._redeemThrottle;
        uint256 oldBlockLimit = throttle.blockLimit;
        uint256 oldDailyLimit = throttle.dailyLimit;
        throttle.blockLimit = newBlockLimit;
        throttle.dailyLimit = newDailyLimit;
        emit UpdatedRedeemThrottle(oldBlockLimit, newBlockLimit, oldDailyLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinWithdraw(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuMinAmountsV3Storage.Layout storage $ = YuzuMinAmountsV3Storage.layout();
        uint256 oldMin = $._minWithdraw;
        $._minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNav(uint256 newNav) external {
        _checkRole(NAV_MANAGER_ROLE);
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
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
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
        uint256 oldStepCapPpm = $._stepCapPpm;
        $._stepCapPpm = newStepCapPpm;
        emit UpdatedNavStepCap(oldStepCapPpm, newStepCapPpm);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setNavCooldown(uint256 newCooldown) external {
        _checkRole(ADMIN_ROLE);
        YuzuNavMarkdownV3Storage.Layout storage $ = YuzuNavMarkdownV3Storage.layout();
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

    function _maxDeposit(address proxy, address receiver) private view returns (uint256) {
        if (_isMarkedDown(proxy) || !_canMint(proxy, receiver)) {
            return 0;
        }
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 baseMax = router.convertToAssets(headroom);
        uint256 maxAssets = Math.min(baseMax, _mintThrottleRemaining(proxy, receiver));
        uint256 min = router.minDeposit();
        return maxAssets < min ? 0 : maxAssets;
    }

    function _maxMint(address proxy, address receiver) private view returns (uint256) {
        if (_isMarkedDown(proxy) || !_canMint(proxy, receiver)) {
            return 0;
        }
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        uint256 headroom = _supplyHeadroom(proxy);
        uint256 remaining = _mintThrottleRemaining(proxy, receiver);
        uint256 shares =
            remaining >= type(uint128).max ? headroom : Math.min(headroom, router.convertToShares(remaining));
        uint256 min = router.minDeposit();
        return router.previewMint(shares) < min ? 0 : shares;
    }

    function _maxWithdraw(address proxy, address owner) private view returns (uint256) {
        if (!_canRedeem(proxy, owner)) {
            return 0;
        }
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        uint256 feePpm = router.redeemFeePpm();
        uint256 liquid = router.liquidityBufferSize();
        uint256 fee = _feeOnTotal(liquid, feePpm);
        uint256 baseMax = Math.min(router.previewRedeem(router.balanceOf(owner)), liquid - fee);
        uint256 remaining = _redeemThrottleRemaining(proxy, owner);
        uint256 throttleMax = remaining - _feeOnTotal(remaining, feePpm);
        uint256 maxAssets = Math.min(baseMax, throttleMax);
        uint256 min = router.minWithdraw();
        return maxAssets < min ? 0 : maxAssets;
    }

    function _maxRedeem(address proxy, address owner) private view returns (uint256) {
        if (!_canRedeem(proxy, owner)) {
            return 0;
        }
        IYuzuUSDV3Router router = IYuzuUSDV3Router(proxy);
        uint256 maxTokens = Math.min(router.convertToShares(router.liquidityBufferSize()), router.balanceOf(owner));
        uint256 remaining = _redeemThrottleRemaining(proxy, owner);
        uint256 shares = router.convertToAssets(maxTokens) <= remaining ? maxTokens : router.convertToShares(remaining);
        uint256 min = router.minWithdraw();
        return router.previewRedeem(shares) < min ? 0 : shares;
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
        uint256 currentNav = YuzuNavMarkdownV3Storage.layout()._nav;
        if (currentNav < NAV_PRECISION) {
            revert MintDisabledWhileMarkedDown(currentNav);
        }
    }

    function _checkMinDeposit(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minDeposit;
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    function _checkMinWithdraw(uint256 assets) private view {
        uint256 min = YuzuMinAmountsV3Storage.layout()._minWithdraw;
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    function _consumeMintThrottle(address account, uint256 assets) private {
        if (_isThrottleExempt(account)) {
            return;
        }
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._mintThrottle;
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
        Throttle storage throttle = YuzuThrottleV3Storage.layout()._redeemThrottle;
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
        YuzuSameBlockGuardV3Storage.layout()._lastMintBlock[receiver] = block.number;
    }

    function _checkSameBlockRedeem(address owner) private view {
        if (_isThrottleExempt(owner)) {
            return;
        }
        if (YuzuSameBlockGuardV3Storage.layout()._lastMintBlock[owner] == block.number) {
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
}
