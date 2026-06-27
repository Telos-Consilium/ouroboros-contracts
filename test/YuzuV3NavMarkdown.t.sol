// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3FeatureFacet} from "../src/YuzuUSDV3FeatureFacet.sol";
import {IYuzuNavMarkdownDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuV3NavMarkdownTest is Test, IYuzuNavMarkdownDefinitions {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    uint256 internal constant PAR = 1e18;

    USDT0Mock asset;
    YuzuUSDV3 yzusd;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address navManager = makeAddr("navManager");
    address filler = makeAddr("filler");
    address user = makeAddr("user");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);
        asset.mint(filler, 10_000_000e6);

        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            address(asset),
            "Yuzu USD",
            "yzUSD",
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        yzusd =
            YuzuUSDV3(address(new ERC1967Proxy(address(new YuzuUSDV3(address(new YuzuUSDV3FeatureFacet()))), initData)));
        yzusd.reinitializeV3();

        vm.startPrank(admin);
        yzusd.grantRole(NAV_MANAGER_ROLE, navManager);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.grantRole(ORDER_FILLER_ROLE, filler);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        // Keep deposits in the contract so the instant redeem buffer is funded
        yzusd.setLiquidityBufferTargetSize(type(uint256).max);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(address(yzusd), type(uint256).max);
        vm.prank(filler);
        asset.approve(address(yzusd), type(uint256).max);
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

    // --- mint disabled while marked down ---

    function test_Markdown_DisablesMintViews() public {
        _setNav(9e17);
        assertEq(yzusd.maxDeposit(user), 0);
        assertEq(yzusd.maxMint(user), 0);
    }

    function test_Markdown_RevertDeposit() public {
        _setNav(9e17);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MintDisabledWhileMarkedDown.selector, 9e17));
        yzusd.deposit(10e6, user);
    }

    function test_Markdown_RevertMint() public {
        _setNav(9e17);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MintDisabledWhileMarkedDown.selector, 9e17));
        yzusd.mint(10e18, user);
    }

    function test_Markdown_RedeemStillAllowed() public {
        uint256 shares = _deposit(user, 100e6);
        vm.roll(block.number + 1);
        _setNav(9e17);

        vm.prank(user);
        assertGt(yzusd.redeem(shares, user, user), 0);
    }

    // --- step cap (both directions) ---

    function test_SetNav_FirstUpdateSkipsCooldown() public {
        _setNav(9e17);
        assertEq(yzusd.nav(), 9e17);
        assertEq(yzusd.navLastUpdate(), block.timestamp);
    }

    function test_SetNav_Revert_StepTooLargeDown() public {
        vm.prank(navManager);
        vm.expectRevert(abi.encodeWithSelector(NavStepTooLarge.selector, 8e17, PAR, 1e17));
        yzusd.setNav(8e17); // -20% exceeds the 10% cap
    }

    function test_SetNav_Revert_StepTooLargeUp() public {
        vm.prank(navManager);
        vm.expectRevert(abi.encodeWithSelector(NavStepTooLarge.selector, 12e17, PAR, 1e17));
        yzusd.setNav(12e17); // +20% exceeds the 10% cap
    }

    function test_SetNav_StepRelativeToCurrent() public {
        _setNav(9e17); // par -> 0.9
        vm.warp(block.timestamp + 1 days);
        // From 0.9 the cap is 10% of 0.9 = 0.09, so 0.81 is allowed
        _setNav(81e16);
        assertEq(yzusd.nav(), 81e16);
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

        // The wider cap now permits a larger step
        vm.prank(navManager);
        yzusd.setNav(6e17); // -40%, within the new 50% cap
        assertEq(yzusd.nav(), 6e17);
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
