// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IntegrationConfig, IStakedYuzuUSDV2Definitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IStakedYuzuUSDV2} from "../src/interfaces/IStakedYuzuUSD.sol";

import {StakedYuzuUSDV2} from "../src/StakedYuzuUSDV2.sol";

import {StakedYuzuUSDTest} from "../test/StakedYuzuUSD.t.sol";

contract StakedYuzuUSDV2Test is StakedYuzuUSDTest, IStakedYuzuUSDV2Definitions {
    IStakedYuzuUSDV2 public styz2;

    function setUp() public override {
        super.setUp();
        styz2 = IStakedYuzuUSDV2(address(styz));
    }

    function _deploy() internal override returns (address) {
        return address(new StakedYuzuUSDV2());
    }

    function _withdrawAndAssert(address caller, uint256 assets, address receiver, address _owner) internal {
        vm.prank(owner);
        styz2.setRedeemDelay(0);

        uint256 expectedShares = styz2.previewWithdraw(assets);
        uint256 expectedFee = Math.ceilDiv(assets * styz2.redeemFeePpm(), 1_000_000);

        uint256 ownerSharesBefore = styz2.balanceOf(_owner);
        uint256 receiverAssetsBefore = yzusd.balanceOf(receiver);
        uint256 feeReceiverAssetsBefore = yzusd.balanceOf(feeReceiver);
        uint256 shareSupplyBefore = styz2.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit IERC4626.Withdraw(caller, receiver, _owner, assets, expectedShares);
        uint256 redeemedShares = styz2.withdraw(assets, receiver, _owner);

        assertEq(redeemedShares, expectedShares);

        assertEq(styz2.balanceOf(_owner), ownerSharesBefore - redeemedShares);
        assertEq(yzusd.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(yzusd.balanceOf(feeReceiver), feeReceiverAssetsBefore + expectedFee);
        assertEq(styz2.totalSupply(), shareSupplyBefore - redeemedShares);
    }

    function _redeemAndAssert(address caller, uint256 shares, address receiver, address _owner) internal {
        vm.prank(owner);
        styz2.setRedeemDelay(0);

        uint256 expectedAssets = styz2.previewRedeem(shares);
        uint256 expectedFee = styz2.convertToAssets(shares) - expectedAssets;

        uint256 ownerSharesBefore = styz2.balanceOf(_owner);
        uint256 receiverAssetsBefore = yzusd.balanceOf(receiver);
        uint256 feeReceiverAssetsBefore = yzusd.balanceOf(feeReceiver);
        uint256 shareSupplyBefore = styz2.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit IERC4626.Withdraw(caller, receiver, _owner, expectedAssets, shares);
        uint256 withdrawnAssets = styz2.redeem(shares, receiver, _owner);

        assertEq(withdrawnAssets, expectedAssets);

        assertEq(styz2.balanceOf(_owner), ownerSharesBefore - shares);
        assertEq(yzusd.balanceOf(receiver), receiverAssetsBefore + withdrawnAssets);
        assertEq(yzusd.balanceOf(feeReceiver), feeReceiverAssetsBefore + expectedFee);
        assertEq(styz2.totalSupply(), shareSupplyBefore - shares);
    }

    // Withdraw
    function test_Withdraw_Revert() public override {
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 100e18, 0)
        );
        styz2.withdraw(100e18, user1, user1);
    }

    function test_Withdraw() public {
        uint256 assets = 100e18;
        vm.prank(user1);
        styz2.deposit(assets, user1);
        _withdrawAndAssert(user1, assets, user2, user1);
    }

    function test_Withdraw_Zero() public {
        _withdrawAndAssert(user1, 0, user2, user1);
    }

    function test_Withdraw_WithFee() public {
        uint256 assets = 100e18;
        uint256 feePpm = 250_000; // 25%

        vm.prank(owner);
        styz2.setRedeemFee(feePpm);

        vm.prank(user1);
        styz2.deposit(assets, user1);

        _withdrawAndAssert(user1, 80e18, user2, user1);
    }

    function test_Withdraw_Revert_RedeemDelay() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 100e18, 0)
        );
        styz2.withdraw(100e18, user1, user1);
    }

    // Redeem
    function test_Redeem_Revert() public override {
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, 100e18, 0));
        styz2.redeem(100e18, user1, user1);
    }

    function test_Redeem() public {
        uint256 shares = 100e18;
        vm.prank(user1);
        styz2.mint(shares, user1);
        _redeemAndAssert(user1, shares, user2, user1);
    }

    function test_Redeem_Zero() public {
        _redeemAndAssert(user1, 0, user2, user1);
    }

    function test_Redeem_WithFee() public {
        uint256 shares = 100e18;
        uint256 feePpm = 100_000; // 10%

        vm.prank(owner);
        styz2.setRedeemFee(feePpm);

        vm.prank(user1);
        styz2.mint(shares, user1);
        _redeemAndAssert(user1, shares, user2, user1);
    }

    function test_Redeem_Revert_RedeemDelay() public {
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, 100e18, 0));
        styz2.redeem(100e18, user1, user1);
    }

    // Integration
    function test_SetIntegration() public {
        address integration = makeAddr("integration");

        vm.prank(owner);
        vm.expectEmit();
        emit UpdatedIntegration(integration, true, true);
        styz2.setIntegration(integration, true, true);

        IntegrationConfig memory cfg = styz2.getIntegration(integration);
        assertTrue(cfg.canSkipRedeemDelay);
        assertTrue(cfg.waiveRedeemFee);
    }

    function test_SetIntegration_Revert_NotOwner() public {
        address integration = makeAddr("integration");
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        styz2.setIntegration(integration, true, true);
    }

    function test_Withdraw_Integration_WithFee() public {
        address integration = makeAddr("integration");
        uint256 feePpm = 50_000; // 5%

        vm.startPrank(owner);
        styz2.setIntegration(integration, true, false);
        styz2.setRedeemFee(feePpm);
        vm.stopPrank();

        uint256 mintedShares = _deposit(user1, 200e18);
        uint256 withdrawAssets = 60e18;
        _approveShares(user1, integration, mintedShares);

        vm.startPrank(integration);
        uint256 expectedShares = styz2.previewWithdraw(withdrawAssets);
        uint256 grossAssets = styz2.convertToAssets(expectedShares);
        uint256 expectedFee = grossAssets - withdrawAssets;
        vm.stopPrank();

        uint256 receiverBalanceBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBalanceBefore = yzusd.balanceOf(feeReceiver);

        vm.prank(integration);
        styz2.withdraw(withdrawAssets, user1, user1);

        assertEq(yzusd.balanceOf(user1) - receiverBalanceBefore, withdrawAssets);
        assertEq(yzusd.balanceOf(feeReceiver) - feeReceiverBalanceBefore, expectedFee);
        assertEq(styz2.balanceOf(user1), mintedShares - expectedShares);
    }

    function test_Withdraw_Integration_NoFee() public {
        address integration = makeAddr("integration");
        uint256 feePpm = 50_000; // 5%

        vm.startPrank(owner);
        styz2.setIntegration(integration, true, true);
        styz2.setRedeemFee(feePpm);
        vm.stopPrank();

        uint256 mintedShares = _deposit(user1, 200e18);
        uint256 withdrawAssets = 80e18;
        _approveShares(user1, integration, mintedShares);

        vm.startPrank(integration);
        uint256 expectedShares = styz2.previewWithdraw(withdrawAssets); // fee waived for this caller
        vm.stopPrank();

        uint256 receiverBalanceBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBalanceBefore = yzusd.balanceOf(feeReceiver);
        uint256 ownerSharesBefore = styz2.balanceOf(user1);

        vm.prank(integration);
        styz2.withdraw(withdrawAssets, user1, user1);

        assertEq(yzusd.balanceOf(user1) - receiverBalanceBefore, withdrawAssets);
        assertEq(yzusd.balanceOf(feeReceiver) - feeReceiverBalanceBefore, 0);
        assertEq(ownerSharesBefore - styz2.balanceOf(user1), expectedShares);
    }

    function test_Redeem_Integration_WithFee() public {
        address integration = makeAddr("integration");
        uint256 feePpm = 100_000; // 10%

        vm.startPrank(owner);
        styz2.setIntegration(integration, true, false);
        styz2.setRedeemFee(feePpm);
        vm.stopPrank();

        uint256 mintedShares = _deposit(user1, 100e18);
        _approveShares(user1, integration, mintedShares);

        vm.startPrank(integration);
        uint256 expectedAssets = styz2.previewRedeem(mintedShares);
        uint256 grossAssets = styz2.convertToAssets(mintedShares);
        uint256 expectedFee = grossAssets - expectedAssets;

        uint256 receiverBalanceBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBalanceBefore = yzusd.balanceOf(feeReceiver);
        uint256 supplyBefore = styz2.totalSupply();

        styz2.redeem(mintedShares, user1, user1);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1) - receiverBalanceBefore, expectedAssets);
        assertEq(yzusd.balanceOf(feeReceiver) - feeReceiverBalanceBefore, expectedFee);
        assertEq(styz2.totalSupply(), supplyBefore - mintedShares);
        assertEq(styz2.balanceOf(user1), 0);
    }

    function test_Redeem_Integration_NoFee() public {
        address integration = makeAddr("integration");
        uint256 feePpm = 100_000; // 10%

        vm.startPrank(owner);
        styz2.setIntegration(integration, true, true);
        styz2.setRedeemFee(feePpm);
        vm.stopPrank();

        uint256 mintedShares = _deposit(user1, 150e18);
        _approveShares(user1, integration, mintedShares);

        vm.startPrank(integration);
        uint256 expectedAssets = styz2.previewRedeem(mintedShares); // fee waived for this caller
        uint256 grossAssets = styz2.convertToAssets(mintedShares);
        vm.stopPrank();

        uint256 receiverBalanceBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBalanceBefore = yzusd.balanceOf(feeReceiver);

        vm.prank(integration);
        styz2.redeem(mintedShares, user1, user1);

        assertEq(expectedAssets, grossAssets); // no fee applied
        assertEq(yzusd.balanceOf(user1) - receiverBalanceBefore, expectedAssets);
        assertEq(yzusd.balanceOf(feeReceiver) - feeReceiverBalanceBefore, 0);
        assertEq(styz2.balanceOf(user1), 0);
    }

    function test_Withdraw_Revert_NotIntegration() public {
        uint256 mintedShares = _deposit(user1, 120e18);
        vm.prank(user1);
        styz2.approve(user1, mintedShares);

        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 10e18, 0));
        styz2.withdraw(10e18, user1, user1);
    }

    function test_Redeem_Revert_NotIntegration() public {
        uint256 mintedShares = _deposit(user1, 120e18);
        vm.prank(user1);
        styz2.approve(user1, mintedShares);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, mintedShares, 0)
        );
        styz2.redeem(mintedShares, user1, user1);
    }

    function test_Preview() public {
        address integration = makeAddr("integration");

        vm.prank(owner);
        styz2.setIntegration(integration, true, true); // waive fee

        vm.prank(owner);
        styz2.setRedeemFee(100_000); // 10%

        uint256 mintedShares = _deposit(user1, 110e18);

        uint256 userPreviewRedeem = styz2.previewRedeem(mintedShares);
        uint256 userPreviewWithdraw = styz2.previewWithdraw(50e18);

        vm.prank(integration);
        uint256 waivedPreviewRedeem = styz2.previewRedeem(mintedShares);
        vm.prank(integration);
        uint256 waivedPreviewWithdraw = styz2.previewWithdraw(50e18);

        assertLt(userPreviewRedeem, mintedShares); // fee applied
        assertGt(waivedPreviewRedeem, userPreviewRedeem); // fee waived
        assertGt(userPreviewWithdraw, 50e18); // fee adds to shares required
        assertEq(waivedPreviewWithdraw, 50e18); // no fee when waived
    }

    function test_MaxWithdrawRedeem_Integration() public {
        address integration = makeAddr("integration");
        uint256 mintedShares = _deposit(user1, 90e18);

        vm.prank(owner);
        styz2.setIntegration(integration, true, false);

        vm.prank(user1);
        assertEq(styz2.maxWithdraw(user1), 0);
        vm.prank(user1);
        assertEq(styz2.maxRedeem(user1), 0);

        vm.prank(integration);
        uint256 maxWithdraw = styz2.maxWithdraw(user1);
        vm.prank(integration);
        uint256 maxRedeem = styz2.maxRedeem(user1);

        assertGt(maxWithdraw, 0);
        assertEq(maxRedeem, mintedShares);
    }

    function test_TerminateDistribution_SameBlock() public {
        vm.prank(owner);
        styz.distribute(1e18, 1 days);
        vm.prank(owner);
        styz.terminateDistribution(owner);
        styz.totalAssets();
    }

    function test_RescueTokens_Revert_ExceedsRescuableBalance() public {
        uint256 depositAmount = 100e18;

        vm.prank(user1);
        uint256 shares = styz2.deposit(depositAmount, user1);

        vm.prank(user1);
        styz2.initiateRedeem(shares, user1, user1);

        assertEq(styz2.totalSupply(), 0);
        assertGt(styz2.totalPendingOrderValue(), 0);

        uint256 contractBalance = yzusd.balanceOf(address(styz2));
        uint256 pendingValue = styz2.totalPendingOrderValue();
        uint256 rescuableBalance = contractBalance - pendingValue;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ExceededRescuableBalance.selector, pendingValue, rescuableBalance));
        styz2.rescueTokens(address(yzusd), owner, pendingValue);
    }
}
