// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuNavMarkdownDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuV3NavMarkdownTest is YuzuV3TestBase, IYuzuNavMarkdownDefinitions {
    uint256 internal constant PAR = 1e18;

    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(filler, 10_000_000e6);

        yzusd = _deployYuzuUSDV3(address(asset), "Yuzu USD", "yzUSD", false);

        vm.startPrank(admin);
        yzusd.grantRole(NAV_MANAGER_ROLE, navManager);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.grantRole(ORDER_FILLER_ROLE, filler);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        yzusd.setLiquidityBufferTargetSize(type(uint256).max);
        vm.stopPrank();

        _approve(user, address(yzusd));
        _approve(filler, address(yzusd));
    }

    // --- helpers ---

    function _deposit(address who, uint256 assets) internal returns (uint256) {
        vm.prank(who);
        return yzusd.deposit(assets, who);
    }

    function _setNav(uint256 newNav) internal {
        vm.prank(navManager);
        yzusd.setNav(newNav);
    }

    // --- seeding ---

    function test_ReinitializeV3_SeedsNavAtPar() public view {
        assertEq(yzusd.nav(), PAR);
        assertEq(yzusd.navStepCapPpm(), 100_000);
        assertEq(yzusd.navCooldown(), 1 days);
        assertEq(yzusd.navLastUpdate(), 0);
        assertFalse(yzusd.isMarkedDown());
        assertEq(yzusd.getRoleAdmin(NAV_MANAGER_ROLE), ADMIN_ROLE);
    }

    function test_AtPar_RedeemOneToOne() public {
        uint256 shares = _deposit(user, 100e6);
        assertEq(shares, 100e18);

        vm.roll(block.number + 1);
        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);
        assertEq(assets, 100e6);
    }

    // --- markdown pricing ---

    function test_Markdown_ReducesRedeemPayout() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);

        _setNav(9e17); // -10%, exactly at the step cap
        assertTrue(yzusd.isMarkedDown());

        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);
        assertEq(assets, 90e6);
    }

    function test_Markdown_WithdrawBurnsMoreShares() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);

        _setNav(9e17);

        // Withdrawing 90 USDT0 burns the full 100e18 shares at the marked-down price
        vm.prank(user);
        uint256 burned = yzusd.withdraw(90e6, user, user);
        assertEq(burned, shares);
        assertEq(yzusd.balanceOf(user), 0);
    }

    function test_Overbacked_RedeemCappedAtPar() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);

        _setNav(11e17); // +10%, above par
        assertFalse(yzusd.isMarkedDown());

        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);
        assertEq(assets, 100e6); // par, not 110e6: markups do not pass to redeemers
    }

    function test_Overbacked_MintStaysAtPar() public {
        _setNav(11e17);
        assertGt(yzusd.maxDeposit(user), 0);

        uint256 shares = _deposit(user, 50e6);
        assertEq(shares, 50e18); // 1:1, the markup does not cheapen minting
    }

    // --- mint pricing while marked down ---

    function test_Markdown_MintViewsRemainOpen() public {
        _setNav(9e17);
        assertGt(yzusd.maxDeposit(user), 0);
        assertGt(yzusd.maxMint(user), 0);
        assertEq(yzusd.previewDeposit(90e6), 100e18);
        assertEq(yzusd.previewMint(100e18), 90e6);
    }

    function test_Markdown_DepositPricesAtNav() public {
        _setNav(9e17);

        vm.prank(user);
        uint256 shares = yzusd.deposit(90e6, user);
        assertEq(shares, 100e18);
    }

    function test_Markdown_MintPricesAtNav() public {
        _setNav(9e17);

        vm.prank(user);
        uint256 assets = yzusd.mint(100e18, user);
        assertEq(assets, 90e6);
        assertEq(yzusd.balanceOf(user), 100e18);
    }

    function test_Markdown_RedeemStillAllowed() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);
        _setNav(9e17);

        vm.prank(user);
        assertGt(yzusd.redeem(shares, user, user), 0);
    }

    // --- step cap ---

    function test_SetNav_FirstUpdateSkipsCooldown() public {
        _setNav(9e17);
        assertEq(yzusd.nav(), 9e17);
        assertEq(yzusd.navLastUpdate(), block.timestamp);
    }

    function test_SetNav_MarkdownBypassesStepCap() public {
        vm.prank(navManager);
        yzusd.setNav(8e17); // -20%; markdowns bypass the 10% recovery cap
        assertEq(yzusd.nav(), 8e17);
    }

    function test_SetNav_Revert_StepTooLargeUp() public {
        vm.prank(navManager);
        vm.expectRevert(abi.encodeWithSelector(NavStepTooLarge.selector, 12e17, PAR, 1e17));
        yzusd.setNav(12e17); // +20% exceeds the 10% cap
    }

    function test_SetNav_RecoveryStepRelativeToCurrent() public {
        _setNav(8e17);
        vm.warp(block.timestamp + 1 days);
        // From 0.8 the cap is 10% of 0.8 = 0.08, so 0.88 is allowed
        _setNav(88e16);
        assertEq(yzusd.nav(), 88e16);
    }

    // --- cooldown ---

    function test_SetNav_Revert_CooldownActive() public {
        _setNav(95e16);
        uint256 readyAt = yzusd.navLastUpdate() + yzusd.navCooldown();

        vm.prank(navManager);
        vm.expectRevert(abi.encodeWithSelector(NavCooldownActive.selector, block.timestamp, readyAt));
        yzusd.setNav(9e17);
    }

    function test_SetNav_CooldownElapsed() public {
        _setNav(95e16);
        vm.warp(block.timestamp + 1 days);
        _setNav(9e17);
        assertEq(yzusd.nav(), 9e17);
    }

    // --- access control (role split) ---

    function test_SetNav_Revert_NotNavManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, NAV_MANAGER_ROLE)
        );
        yzusd.setNav(9e17);
    }

    function test_SetNavStepCap_Revert_NavManagerCannot() public {
        // The nav-setter cannot relax its own guardrails; only ADMIN_ROLE can
        vm.prank(navManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, navManager, ADMIN_ROLE)
        );
        yzusd.setNavStepCap(500_000);
    }

    function test_SetNavCooldown_Revert_NavManagerCannot() public {
        vm.prank(navManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, navManager, ADMIN_ROLE)
        );
        yzusd.setNavCooldown(0);
    }

    function test_SetNavStepCap_Revert_TooHigh() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidNavStepCap.selector, 1e6 + 1, 1e6));
        yzusd.setNavStepCap(1e6 + 1);
    }

    function test_SetNavStepCap_Updates() public {
        vm.prank(admin);
        yzusd.setNavStepCap(500_000);
        assertEq(yzusd.navStepCapPpm(), 500_000);

        // The wider cap now permits a larger recovery step
        vm.prank(navManager);
        yzusd.setNav(14e17); // +40%, within the new 50% cap
        assertEq(yzusd.nav(), 14e17);
    }

    function test_SetNavCooldown_Updates() public {
        vm.prank(admin);
        yzusd.setNavCooldown(0);
        assertEq(yzusd.navCooldown(), 0);

        // With no cooldown, back-to-back updates are allowed
        _setNav(95e16);
        _setNav(9e17);
        assertEq(yzusd.nav(), 9e17);
    }

    // --- events ---

    function test_SetNav_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(yzusd));
        emit UpdatedNav(PAR, 9e17);
        _setNav(9e17);
    }

    // --- order path inherits the markdown at fill time ---

    function test_PreviewRedeemOrder_ReflectsMarkdown() public {
        assertEq(yzusd.previewRedeemOrder(100e18), 100e6);
        _setNav(9e17);
        assertEq(yzusd.previewRedeemOrder(100e18), 90e6);
    }

    function test_OrderPath_FillsAtMarkedDownRate() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);

        vm.prank(user);
        uint256 orderId = yzusd.createRedeemOrder(shares, user, user);

        // Markdown lands after the order is queued but before it is filled
        _setNav(9e17);

        vm.prank(filler);
        yzusd.fillRedeemOrder(orderId);
        assertEq(yzusd.getRedeemOrder(orderId).assets, 90e6);

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        yzusd.finalizeRedeemOrder(orderId);
        assertEq(asset.balanceOf(user) - balBefore, 90e6);
    }
}
