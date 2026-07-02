// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuProtoDefinitions, IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuILPV3FeesTest is YuzuV3TestBase, IYuzuProtoDefinitions, IYuzuILPV2Definitions, IYuzuILPV3Definitions {
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        yzilp = _deployYuzuILPV3();

        vm.startPrank(admin);
        yzilp.grantRole(FEE_MANAGER_ROLE, feeManager);
        yzilp.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
    }

    function _setMintFee(uint256 ppm) internal {
        vm.prank(feeManager);
        yzilp.setMintFee(ppm);
    }

    // --- mint fee on the deposit/mint paths ---

    function test_MintFee_DefaultsToZero() public {
        assertEq(yzilp.mintFeePpm(), 0);

        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);
        assertEq(shares, 100e18);
        assertEq(asset.balanceOf(feeReceiver), 0);
    }

    function test_MintFee_OnDeposit() public {
        _setMintFee(100_000); // 10%

        // 110 in: 10 fee to receiver, 100 net backing 100e18 shares
        vm.prank(user);
        uint256 shares = yzilp.deposit(110e6, user);
        assertEq(shares, 100e18);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
    }

    function test_MintFee_OnMint() public {
        _setMintFee(100_000); // 10%

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 paid = yzilp.mint(100e18, user);

        // 100 net for the shares + 10 fee on top
        assertEq(paid, 110e6);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
        assertEq(balBefore - asset.balanceOf(user), 110e6);
    }

    function test_SetMintFee_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedMintFee(0, 100_000);
        _setMintFee(100_000);
        assertEq(yzilp.mintFeePpm(), 100_000);
    }

    function test_SetMintFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1e6 + 1, 1e6));
        yzilp.setMintFee(1e6 + 1);
    }

    function test_SetMintFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setMintFee(100_000);
    }

    // --- redeem fee setters re-homed onto FEE_MANAGER_ROLE ---

    function test_SetRedeemFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemFee(5_000);
        assertEq(yzilp.redeemFeePpm(), 5_000);
    }

    function test_SetRedeemFee_Revert_RedeemManagerRejected() public {
        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemFee(5_000);
    }

    function test_SetRedeemOrderFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemOrderFee(3_000);
        assertEq(yzilp.redeemOrderFeePpm(), 3_000);

        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemOrderFee(3_000);
    }

    // --- feeReceiver stays under ADMIN_ROLE ---

    function test_SetFeeReceiver_StaysAdmin() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        yzilp.setFeeReceiver(newReceiver);
        assertEq(yzilp.feeReceiver(), newReceiver);
    }

    function test_SetFeeReceiver_Revert_FeeManagerRejected() public {
        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, ADMIN_ROLE)
        );
        yzilp.setFeeReceiver(makeAddr("newReceiver"));
    }

    function test_FeeManagerRole_AdminIsAdminRole() public view {
        assertEq(yzilp.getRoleAdmin(FEE_MANAGER_ROLE), ADMIN_ROLE);
    }

    // --- management fee ---

    function _setupPool() internal {
        vm.prank(admin);
        yzilp.grantRole(POOL_MANAGER_ROLE, admin);
        _setupIlpPool(1000e6);
    }

    function _promote(uint256 yieldPpm) internal {
        _promoteIlpFees(yieldPpm);
    }

    function _reportPool(uint256 newPoolSize) internal {
        _reportIlpPool(newPoolSize);
    }

    function test_ManagementFee_DefaultsToZero() public view {
        assertEq(yzilp.managementFeeRatePpm(), 0);
        assertEq(yzilp.pendingManagementFeeRatePpm(), 0);
        assertEq(yzilp.cumulativeManagementFees(), 0);
    }

    function test_PreviewDeposit_UsesCeilRoundedActiveDistribution() public {
        _setupPool();

        vm.prank(admin);
        yzilp.distribute(1, 2);
        vm.warp(block.timestamp + 1);

        assertEq(yzilp.totalAssets(), 1000e6);
        uint256 expectedShares = 1000e6 * yzilp.totalSupply() / (1000e6 + 1);
        assertEq(yzilp.previewDeposit(1000e6), expectedShares);
    }

    function test_SetPendingManagementFee_Deferred() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        // Staged, not yet live
        assertEq(yzilp.pendingManagementFeeRatePpm(), 100_000);
        assertEq(yzilp.managementFeeRatePpm(), 0);
        // The next update promotes it
        _promote(0);
        assertEq(yzilp.managementFeeRatePpm(), 100_000);
    }

    function test_ManagementFee_DriftsNavDown() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr, live next period
        _promote(0);

        assertEq(yzilp.totalAssets(), 1000e6);
        vm.warp(block.timestamp + 365 days);
        // 10% of 1000e6 accrued to the treasury over a year, lowering reported NAV
        assertEq(yzilp.totalAssets(), 900e6);
    }

    function test_ManagementFee_RealizedAtUpdatePool() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);
        vm.warp(block.timestamp + 365 days);

        // Admin reports the gross (1000e6); the contract nets the accrued 100e6 into poolSize
        _reportPool(1000e6);

        assertEq(yzilp.poolSize(), 900e6);
        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.totalAssets(), 900e6);
    }

    function test_ManagementFee_RealizedEmitsEvent() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit RealizedManagementFee(100e6, 100e6);
        vm.prank(admin);
        yzilp.updatePool(1000e6, 1000e6, 0);
    }

    function test_SetPendingManagementFee_EmitsEvent() public {
        _setupPool();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedPendingManagementFee(0, 20_000);
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(20_000);
        // Event reflects the staged transition; the rate is not live until the next update
        assertEq(yzilp.pendingManagementFeeRatePpm(), 20_000);
        assertEq(yzilp.managementFeeRatePpm(), 0);
    }

    function test_SetPendingManagementFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 100_000 + 1, 100_000));
        yzilp.setPendingManagementFee(100_000 + 1);
    }

    function test_SetPendingManagementFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setPendingManagementFee(20_000);
    }

    // --- performance fee ---

    function test_PerformanceFee_DefaultsToZero() public view {
        assertEq(yzilp.performanceFeeRatePpm(), 0);
        assertEq(yzilp.pendingPerformanceFeeRatePpm(), 0);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }

    function test_HighWaterMark_SetAtFirstUpdate() public {
        _setupPool();
        // 1000e6 of assets over 1000e18 shares is 1e6 per whole share
        assertEq(yzilp.highWaterMark(), 1e6);
    }

    function test_SetPendingPerformanceFee_Deferred() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        assertEq(yzilp.pendingPerformanceFeeRatePpm(), 200_000);
        assertEq(yzilp.performanceFeeRatePpm(), 0);
        _promote(0);
        assertEq(yzilp.performanceFeeRatePpm(), 200_000);
    }

    function test_SetPendingPerformanceFee_EmitsEvent() public {
        _setupPool();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedPendingPerformanceFee(0, 200_000);
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
    }

    function test_SetPendingPerformanceFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1e6 + 1, 1e6));
        yzilp.setPendingPerformanceFee(1e6 + 1);
    }

    function test_SetPendingPerformanceFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setPendingPerformanceFee(200_000);
    }

    function test_PerformanceFee_MarksDownGainAboveHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000); // 20%
        _promote(10_000); // live, plus 1%/day yield

        vm.warp(block.timestamp + 10 days); // +10% yield = +100e6 over poolSize 1000e6
        // net of management fee is 1100e6; mark is 1000e6; 20% of the 100e6 gain is 20e6
        assertEq(yzilp.totalAssets(), 1080e6);
    }

    function test_PerformanceFee_RealizedAndAdvancesHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(10_000);
        vm.warp(block.timestamp + 10 days);

        vm.prank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit RealizedPerformanceFee(20e6, 20e6);
        vm.prank(admin);
        yzilp.updatePool(1000e6, 1100e6, 0);

        assertEq(yzilp.poolSize(), 1080e6);
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
        // Mark advances to the pre-fee net-of-management high: 1100e6 / 1000 = 1.1e6
        assertEq(yzilp.highWaterMark(), 1.1e6);
    }

    function test_PerformanceFee_ChargedOnDistributionAboveHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        vm.prank(admin);
        yzilp.distribute(100e6, 1 days);
        vm.warp(block.timestamp + 1 days); // fully vested
        // net of management fee is 1100e6; mark is 1000e6; 20% of the 100e6 gain is 20e6
        assertEq(yzilp.totalAssets(), 1080e6);
    }

    function test_PerformanceFee_RecoveryToHWMFree() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        _reportPool(900e6); // a loss below the mark, no fee
        assertEq(yzilp.cumulativePerformanceFees(), 0);
        _reportPool(1000e6); // recovery back up to the mark, still no fee
        assertEq(yzilp.cumulativePerformanceFees(), 0);
        _reportPool(1100e6); // now above the mark: fee on the 100e6 above 1000e6
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
    }

    function test_PerformanceFee_EnableIsNotRetroactive() public {
        _setupPool();
        // The pool climbs from 1000e6 to 1500e6 while the fee is off
        _reportPool(1500e6);
        assertEq(yzilp.highWaterMark(), 1.5e6);

        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0); // goes live with the mark already at the 1.5e6 high

        _reportPool(1600e6); // fee only on the 100e6 made after enabling
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
    }

    function test_PerformanceFee_DepositDoesNotTriggerFee() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        // A deposit lifts assets and supply together, leaving the per-share price at the mark
        vm.prank(user);
        yzilp.deposit(500e6, user);
        assertEq(yzilp.totalAssets(), 1500e6);

        _reportPool(1500e6);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }

    // A redeem order is priced at the fee-net share price, so filling it is a fair redeem that must not
    // move the share price for the remaining holders. Probes the _fillRedeemOrder pool/distribution split,
    // which sizes itself off the fee-free totalAssets while the payout was priced off the fee-net totalAssets.
    function test_OrderFill_PreservesSharePrice_WithLiveManagementFee() public {
        _setupPool(); // poolSize 1000e6, supply 1000e18
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        _promote(0);

        vm.warp(block.timestamp + 365 days); // markdown 100e6, share price 0.9

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(100e18, user, user); // 10% of supply

        address filler = makeAddr("filler");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        asset.mint(filler, 1_000e6);
        vm.prank(filler);
        asset.approve(address(yzilp), type(uint256).max);
        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 1, "order fill moved the share price while a fee was live");
    }

    function testFuzz_OrderFill_NoPoolUnderflow(uint256 warpDays, uint256 redeemShares) public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);

        warpDays = bound(warpDays, 0, 3000);
        redeemShares = bound(redeemShares, 1e18, 1000e18);
        vm.warp(block.timestamp + warpDays * 1 days);

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(redeemShares, user, user);

        address orderFiller = makeAddr("orderFiller");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        asset.mint(orderFiller, 10_000e6);
        vm.prank(orderFiller);
        asset.approve(address(yzilp), type(uint256).max);

        vm.prank(orderFiller);
        yzilp.fillRedeemOrder(orderId);

        assertLe(yzilp.poolSize(), 1000e6);
    }

    function test_TerminateDistribution_FreezesAtVested() public {
        _setupPool(); // poolSize 1000e6

        uint256 start = block.timestamp;
        vm.prank(admin);
        yzilp.distribute(100e6, 10 hours);

        vm.warp(start + 1 hours); // 1/10 vested
        assertEq(yzilp.totalAssets(), 1010e6);

        vm.expectEmit(false, false, false, true, address(yzilp));
        emit TerminatedDistribution(90e6);
        vm.prank(admin);
        yzilp.terminateDistribution();

        assertEq(yzilp.totalAssets(), 1010e6);
        vm.warp(start + 100 hours);
        assertEq(yzilp.totalAssets(), 1010e6, "totalAssets kept rising after termination");
    }

    function test_TerminateDistribution_Revert_NotPoolManager() public {
        _setupPool();
        vm.prank(admin);
        yzilp.distribute(50e6, 1 days);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, POOL_MANAGER_ROLE)
        );
        yzilp.terminateDistribution();
    }

    // --- mint fee preview and max coupling ---

    function testFuzz_MintFee_PreviewDepositMatchesDeposit(uint256 feePpm, uint256 assets) public {
        _setupPool();
        feePpm = bound(feePpm, 0, 1e6);
        assets = bound(assets, 1, 1_000_000e6);
        _setMintFee(feePpm);

        uint256 previewed = yzilp.previewDeposit(assets);
        uint256 balanceBefore = yzilp.balanceOf(user);
        vm.prank(user);
        uint256 tokens = yzilp.deposit(assets, user);

        assertEq(tokens, previewed);
        assertEq(yzilp.balanceOf(user) - balanceBefore, previewed);
    }

    function testFuzz_MintFee_PreviewMintMatchesMint(uint256 feePpm, uint256 tokens) public {
        _setupPool();
        feePpm = bound(feePpm, 0, 1e6);
        tokens = bound(tokens, 1, 1_000_000e18);
        _setMintFee(feePpm);

        uint256 previewedCost = yzilp.previewMint(tokens);
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 paid = yzilp.mint(tokens, user);

        assertEq(paid, previewedCost);
        assertEq(balanceBefore - asset.balanceOf(user), previewedCost);
    }

    function testFuzz_MintFee_DepositMaxDepositExhaustsThrottle(uint256 feePpm) public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        feePpm = bound(feePpm, 0, 1e6);
        _setMintFee(feePpm);
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 500e6);
        vm.stopPrank();

        uint256 maxAssets = yzilp.maxDeposit(user);
        vm.prank(user);
        yzilp.deposit(maxAssets, user);

        assertEq(yzilp.maxDeposit(user), 0);
    }

    function testFuzz_MintFee_DepositAboveMaxReverts(uint256 feePpm) public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        feePpm = bound(feePpm, 0, 1e6);
        _setMintFee(feePpm);
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 500e6);
        vm.stopPrank();

        uint256 maxAssets = yzilp.maxDeposit(user);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IYuzuIssuerDefinitions.ExceededMaxDeposit.selector, user, maxAssets + 1, maxAssets)
        );
        yzilp.deposit(maxAssets + 1, user);
    }

    function test_MintFee_MaxDepositIsGrossOfFee() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        vm.stopPrank();

        // 100 net budget costs 110 gross at a 10% fee
        assertEq(yzilp.maxDeposit(user), 110e6);
    }

    function test_MintFee_MaxDepositMinClampUsesGross() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        assertEq(yzilp.maxDeposit(user), 110e6);

        vm.prank(admin);
        yzilp.setMinDeposit(110e6 + 1);
        assertEq(yzilp.maxDeposit(user), 0);
    }

    function test_MintFee_MaxMintMinClampUsesGrossCost() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        // 100e18 tokens cost 110e6 gross, meeting the minimum exactly
        assertEq(yzilp.maxMint(user), 100e18);

        vm.prank(admin);
        yzilp.setMinDeposit(110e6 + 1);
        assertEq(yzilp.maxMint(user), 0);
    }

    function test_MintFee_MinDepositAppliesToGrossInput() public {
        _setupPool();
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        vm.prank(user);
        yzilp.deposit(110e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinDeposit.selector, 110e6 - 1, 110e6));
        yzilp.deposit(110e6 - 1, user);
    }
}
