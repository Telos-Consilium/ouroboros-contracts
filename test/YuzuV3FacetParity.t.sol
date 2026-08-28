// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuV3Fees} from "../src/libraries/YuzuV3Fees.sol";
import {
    FEE_MANAGER_ROLE,
    MARKDOWN_STEP_EXEMPT_ROLE,
    NAV_MANAGER_ROLE,
    REDEEMER_ROLE,
    REDEEM_MANAGER_ROLE,
    RESTRICTION_MANAGER_ROLE
} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

/// @dev Covers the facet's redemption pricing and gating: instant redemptions must settle
/// exactly at the public quotes, and the redeem restriction must close the instant and order paths
/// together.
contract YuzuV3FacetParityTest is YuzuV3TestBase {
    uint256 internal constant PAR = 1e18;

    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);

        yzusd = _deployYuzuUSDV3();

        vm.startPrank(admin);
        yzusd.grantRole(NAV_MANAGER_ROLE, navManager);
        yzusd.grantRole(MARKDOWN_STEP_EXEMPT_ROLE, navManager);
        yzusd.grantRole(FEE_MANAGER_ROLE, admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.grantRole(RESTRICTION_MANAGER_ROLE, admin);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        yzusd.setLiquidityBufferTargetSize(type(uint256).max);
        vm.stopPrank();

        _approve(user, address(yzusd));
    }

    function _setupBacking(uint256 nav_, uint256 feePpm) internal {
        vm.prank(user);
        yzusd.deposit(1_000_000e6, user);
        vm.prank(admin);
        yzusd.setRedeemFee(feePpm);
        if (nav_ != PAR) {
            vm.prank(navManager);
            yzusd.setNavUpdateInProgress(true);
            vm.prank(navManager);
            yzusd.setNav(nav_);
            vm.prank(navManager);
            yzusd.setNavUpdateInProgress(false);
        }
        vm.roll(block.number + 1);
    }

    // --- instant redemptions settle at the preview quote ---

    function testFuzz_Redeem_SettlesAtPreviewRedeemQuote(uint256 nav_, uint256 feePpm, uint256 shares) public {
        nav_ = bound(nav_, 5e17, 11e17);
        feePpm = bound(feePpm, 0, 100_000);
        _setupBacking(nav_, feePpm);
        shares = bound(shares, 1, yzusd.balanceOf(user));

        uint256 quote = yzusd.previewRedeem(shares);
        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);

        assertEq(assets, quote, "redeem settled away from the previewRedeem quote");
    }

    function testFuzz_Withdraw_SettlesAtPreviewWithdrawQuote(uint256 nav_, uint256 feePpm, uint256 assets) public {
        nav_ = bound(nav_, 5e17, 11e17);
        feePpm = bound(feePpm, 0, 100_000);
        _setupBacking(nav_, feePpm);
        uint256 maxAssets = yzusd.maxWithdraw(user);
        vm.assume(maxAssets > 0);
        assets = bound(assets, 1, maxAssets);

        uint256 quotedTokens = yzusd.previewWithdraw(assets);
        uint256 userBefore = asset.balanceOf(user);
        uint256 feeReceiverBefore = asset.balanceOf(feeReceiver);
        vm.prank(user);
        uint256 tokens = yzusd.withdraw(assets, user, user);

        assertEq(tokens, quotedTokens, "withdraw burned a different amount than the previewWithdraw quote");
        assertEq(asset.balanceOf(user) - userBefore, assets, "withdraw paid out a different net amount");
        assertEq(
            asset.balanceOf(feeReceiver) - feeReceiverBefore,
            YuzuV3Fees.feeOnRaw(assets, feePpm),
            "withdraw charged a fee different from the quoted split"
        );
    }

    // --- the redeem restriction gates the instant and order paths alike ---

    function test_RedeemRestriction_GatesInstantAndOrderPathsAlike() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        vm.prank(admin);
        yzusd.setIsRedeemRestricted(true);

        assertEq(yzusd.maxWithdraw(user), 0, "restricted withdraw stayed open");
        assertEq(yzusd.maxRedeem(user), 0, "restricted redeem stayed open");
        assertEq(yzusd.maxRedeemOrder(user), 0, "restricted redeem order stayed open");

        vm.prank(admin);
        yzusd.grantRole(REDEEMER_ROLE, user);

        assertGt(yzusd.maxWithdraw(user), 0, "redeemer cannot withdraw");
        assertGt(yzusd.maxRedeem(user), 0, "redeemer cannot redeem");
        assertGt(yzusd.maxRedeemOrder(user), 0, "redeemer cannot create a redeem order");
    }

    // --- fee setters answer to the fee manager; the liquidity buffer answers to the redeem manager ---

    function test_FeeSetters_GateOnFeeManager_NotRedeemManager() public {
        vm.startPrank(admin);
        yzusd.grantRole(FEE_MANAGER_ROLE, feeManager);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        vm.stopPrank();

        vm.startPrank(feeManager);
        yzusd.setRedeemFee(1_000);
        yzusd.setRedeemOrderFee(2_000);
        vm.stopPrank();

        vm.startPrank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzusd.setRedeemFee(1_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzusd.setRedeemOrderFee(2_000);
        yzusd.setLiquidityBufferTargetSize(1);
        vm.stopPrank();

        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, REDEEM_MANAGER_ROLE
            )
        );
        yzusd.setLiquidityBufferTargetSize(1);
    }
}
