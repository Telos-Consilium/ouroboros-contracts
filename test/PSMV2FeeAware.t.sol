// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PSMV2Test} from "./PSMV2.t.sol";
import {
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    MINTER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    REDEEM_MANAGER_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./helpers/TestRoles.sol";

/// @dev PSM redemption accounting must be correct whether or not the PSM holds syzUSD's
/// REDEEM_FEE_EXEMPT_ROLE. The base fixture grants the exemption; these tests exercise both modes.
contract PSMV2FeeAwareTest is PSMV2Test {
    uint256 internal constant FEE = 10_000; // 1% instant redeem fee

    function _nonExempt(uint256 feePpm) internal {
        vm.startPrank(admin);
        styzV3.grantRole(FEE_MANAGER_ROLE, admin);
        styzV3.revokeRole(REDEEM_FEE_EXEMPT_ROLE, address(psmV2));
        styzV3.setInstantRedeemFee(feePpm);
        vm.stopPrank();
    }

    function _setStyzMinWithdraw(uint256 min) internal {
        vm.startPrank(admin);
        styzV3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styzV3.setMinWithdraw(min);
        vm.stopPrank();
    }

    // --- preview matches execution in both modes ---

    function test_PreviewRedeem_MatchesExecution_Exempt() public {
        uint256 shares = _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        uint256 preview = psmV2.previewRedeem(shares);
        uint256 actual = _redeem(user1, shares);
        assertEq(preview, actual, "exempt preview diverged from execution");
    }

    function test_PreviewRedeem_MatchesExecution_NonExempt() public {
        uint256 shares = _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);

        uint256 preview = psmV2.previewRedeem(shares);
        uint256 actual = _redeem(user1, shares);
        assertEq(preview, actual, "non-exempt preview diverged from execution");
        assertApproxEqAbs(actual, 990e6, 1e6, "fee not applied to the net");
    }

    // The exempt preview overstates what a non-exempt redeem returns; the fee-aware one does not.
    function test_PreviewRedeem_FeeAware_LowerThanFeeFree() public {
        uint256 shares = _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        uint256 exemptPreview = psmV2.previewRedeem(shares);
        _nonExempt(FEE);
        assertLt(psmV2.previewRedeem(shares), exemptPreview, "non-exempt preview should net the fee");
    }

    // --- maxRedeem limits ---

    function test_MaxRedeem_ExactAmountExecutes_NonExempt() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);

        uint256 max = psmV2.maxRedeem(user1);
        assertGt(max, 0, "fixture: expected a redeemable maximum");
        assertGt(_redeem(user1, max), 0, "redeeming the reported maximum produced no assets");
    }

    // Throttle binds: the reported max nets within the budget and is one-share tight (max+1 reaches
    // the budget). Exercises the fee-aware inverse and its clamp.
    function test_MaxRedeem_ThrottleBound_TightNonExempt() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);
        vm.prank(limitManager);
        psmV2.setRedeemThrottle(500e6, 500e6);

        uint256 max = psmV2.maxRedeem(user1);
        assertGt(max, 0, "fixture: expected a throttle-bound maximum");
        assertLt(max, styzV3.balanceOf(user1), "fixture: throttle should bind below the balance");
        assertLe(psmV2.previewRedeem(max), 500e6, "reported max over-reports the net budget");
        assertGe(psmV2.previewRedeem(max + 1), 500e6, "reported max under-reports by more than a share");
        assertLe(_redeem(user1, max), 500e6, "redeeming the max exceeded the budget");
    }

    // Maximum when PSM liquidity binds: proves the fee-free super.maxRedeem liquidity ceiling was
    // replaced with a net one. Same no-over-report and one-share tightness as above.
    function test_MaxRedeem_LiquidityBound_TightNonExempt() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);

        // Drop PSM liquidity below the position's net value so liquidity binds.
        vm.prank(liquidityManager);
        psmV2.withdrawLiquidity(LIQUIDITY - 500e6, liquidityManager);
        assertEq(psmV2.liquidity(), 500e6, "fixture: liquidity setup");

        uint256 max = psmV2.maxRedeem(user1);
        assertGt(max, 0, "fixture: expected a liquidity-bound maximum");
        assertLt(max, styzV3.balanceOf(user1), "fixture: liquidity should bind below the balance");
        assertLe(psmV2.previewRedeem(max), 500e6, "reported max over-reports the liquidity");
        assertGe(psmV2.previewRedeem(max + 1), 500e6, "reported max under-reports liquidity by more than a share");
        assertGt(_redeem(user1, max), 0, "redeeming the liquidity-bound max failed");
    }

    // A minimum set just below the budget: the fee-aware max clears it and executes, where a fee-free
    // cap would net ~1% less, fall under the minimum, and DoS.
    function test_MaxRedeem_NonZero_AtBudgetMinimumBoundary_NonExempt() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);

        vm.startPrank(limitManager);
        psmV2.setRedeemThrottle(500e6, 500e6); // net budget 500e6
        psmV2.setMinWithdraw(498e6); // below the budget but above a fee-free cap's ~495e6 net
        vm.stopPrank();

        uint256 max = psmV2.maxRedeem(user1);
        assertGt(max, 0, "fee-aware max must reach the budget and clear the minimum");
        uint256 out = _redeem(user1, max);
        assertGe(out, 498e6, "redeemed below the minimum");
        assertLe(out, 500e6, "redeemed above the budget");
    }

    // --- minimums are checked on the fee-net proceeds ---

    // Inner (syzUSD) minimum: gross proceeds clear styz.minWithdraw but the fee-net do not, so
    // maxRedeem must be zero even though the PSM's own minimum is zero.
    function test_MaxRedeem_Zero_WhenNetBelowInnerMin() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);

        uint256 shares = styzV3.balanceOf(user1);
        uint256 gross = styzV3.convertToAssets(shares);
        uint256 net = styzV3.previewRedeem(shares);
        assertLt(net, gross, "fixture: fee should reduce net");
        _setStyzMinWithdraw(gross); // net < gross == inner minimum

        vm.prank(limitManager);
        psmV2.setMinWithdraw(0); // outer minimum is not the binding one

        assertEq(psmV2.maxRedeem(user1), 0, "inner syzUSD minimum should bind on fee-net proceeds");
    }

    // Outer (PSM) minimum: the whole position nets below the PSM minWithdraw after the fee.
    function test_MaxRedeem_Zero_WhenNetBelowOuterMin() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        _nonExempt(FEE);
        vm.prank(limitManager);
        psmV2.setMinWithdraw(100e6); // net (~99e6) is below this

        assertEq(psmV2.maxRedeem(user1), 0, "fee-net position below the PSM minimum should report 0");
    }

    // --- exempt mode is preserved exactly ---

    // Setting a nonzero instant fee while the PSM stays exempt must not change its maximum or
    // preview: the PSM's effective fee stays zero.
    function test_MaxRedeem_ExemptUnchanged_ByFeeRate() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        uint256 maxBefore = psmV2.maxRedeem(user1);
        uint256 previewBefore = psmV2.previewRedeem(maxBefore);

        vm.startPrank(admin);
        styzV3.grantRole(FEE_MANAGER_ROLE, admin);
        styzV3.setInstantRedeemFee(FEE);
        vm.stopPrank();

        assertEq(psmV2.maxRedeem(user1), maxBefore, "exempt maximum changed with the fee rate");
        assertEq(psmV2.previewRedeem(maxBefore), previewBefore, "exempt preview changed with the fee rate");
    }

    // --- non-par conversion rate ---

    // Raise syzUSD's conversion rate above par via a completed distribution, so the vault1 leg is
    // non-par when the fee-aware inverse and its clamp run, and assert the same bounded-max
    // property: the reported maximum does not over-report the budget and executes.
    function test_MaxRedeem_BoundedMax_NonParRate_NonExempt() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);

        // Mint yzUSD to the distributor and stream a completed distribution so syzUSD is above par.
        asset.mint(admin, 50e6);
        vm.startPrank(admin);
        yzusd.grantRole(MINTER_ROLE, admin); // minting is gated on the receiver holding MINTER_ROLE
        asset.approve(address(yzusd), 50e6);
        uint256 yzMinted = yzusd.deposit(50e6, admin);
        styzV3.grantRole(DISTRIBUTOR_ROLE, admin);
        yzusd.approve(address(styzV3), yzMinted);
        styzV3.distribute(yzMinted, 1 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);
        assertGt(styzV3.convertToAssets(1e18), 1e18, "fixture: syzUSD rate should be above par");

        _nonExempt(FEE);
        vm.prank(limitManager);
        psmV2.setRedeemThrottle(500e6, 500e6);

        uint256 max = psmV2.maxRedeem(user1);
        assertGt(max, 0, "fixture: expected a throttle-bound maximum at a non-par rate");
        assertLt(max, styzV3.balanceOf(user1), "fixture: throttle should bind below the balance");
        assertLe(psmV2.previewRedeem(max), 500e6, "reported max over-reports at a non-par rate");
        assertGe(psmV2.previewRedeem(max + 1), 500e6, "reported max under-reports by more than a share");
        assertLe(_redeem(user1, max), 500e6, "redeeming the max exceeded the budget at a non-par rate");
    }

    // --- one-step rounding correction is sufficient ---

    // Fuzz the fee, deposit, and redeem-throttle budget, and assert the reported maximum never
    // over-reports (its net stays within budget) and executes here. This exercises the single-step
    // clamp in _netSharesWithinBudget across the par-rate conversion and fee rounding; the non-par
    // conversion case is covered deterministically by test_MaxRedeem_BoundedMax_NonParRate_NonExempt.
    function testFuzz_MaxRedeem_ExecutableAndWithinBudget(uint256 deposit, uint256 throttle, uint256 feePpm)
        public
    {
        deposit = bound(deposit, 1e6, 1_000_000e6);
        throttle = bound(throttle, 1e6, 2_000_000e6);
        feePpm = bound(feePpm, 0, 100_000); // up to 10%

        _deposit(user1, deposit);
        vm.roll(block.number + 1);
        _nonExempt(feePpm);
        vm.prank(limitManager);
        psmV2.setRedeemThrottle(throttle, throttle);

        uint256 max = psmV2.maxRedeem(user1);
        if (max == 0) return;
        assertLe(psmV2.previewRedeem(max), throttle, "reported max over-reports the net budget");
        uint256 out = _redeem(user1, max);
        assertLe(out, throttle, "redeeming the max exceeded the net budget");
    }

    // --- maxRedeemOrder limits ---

    function _setStyzRedeemThrottle(uint256 blockLimit, uint256 dailyLimit) internal {
        vm.startPrank(admin);
        styzV3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styzV3.setRedeemThrottle(blockLimit, dailyLimit);
        vm.stopPrank();
    }

    function _grantPsmStyzThrottleExempt() internal {
        vm.prank(admin);
        styzV3.grantRole(THROTTLE_EXEMPT_ROLE, address(psmV2));
    }

    function _setPsmMinRedeemOrder(uint256 newMin) internal {
        vm.startPrank(admin);
        psmV2.grantRole(REDEEM_MANAGER_ROLE, admin);
        psmV2.setMinRedeemOrder(newMin);
        vm.stopPrank();
    }

    // A position that nets below the PSM minimum quotes 0; the reported max would revert at creation.
    function test_MaxRedeemOrder_Zero_BelowPsmMinWithdraw() public {
        _deposit(user1, 1e6);
        vm.roll(block.number + 1);
        vm.prank(limitManager);
        psmV2.setMinWithdraw(2e6);
        assertEq(psmV2.maxRedeemOrder(user1), 0, "below the PSM minWithdraw should quote 0");
    }

    // The inner syzUSD minimum (enforced at fill) binds even when the PSM minimum does not.
    function test_MaxRedeemOrder_Zero_BelowInnerStyzMinWithdraw() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        uint256 innerGross = styzV3.convertToAssets(styzV3.balanceOf(user1));
        _setStyzMinWithdraw(innerGross + 1);
        vm.prank(limitManager);
        psmV2.setMinWithdraw(0);
        assertEq(psmV2.maxRedeemOrder(user1), 0, "below the inner syzUSD minWithdraw should quote 0");
    }

    // An order minimum above the balance quotes 0.
    function test_MaxRedeemOrder_Zero_BelowMinRedeemOrder() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        _setPsmMinRedeemOrder(styzV3.balanceOf(user1) + 1);
        assertEq(psmV2.maxRedeemOrder(user1), 0, "below minRedeemOrder should quote 0");
    }

    // The PSM-minimum floor is measured on the fee-net proceeds: a min between gross and net quotes 0
    // only in the non-exempt mode.
    function test_MaxRedeemOrder_Zero_WhenFeeNetBelowPsmMin_NonExempt() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        vm.prank(limitManager);
        psmV2.setMinWithdraw(99_500_000); // above the ~99e6 fee-net, below the 100e6 gross
        assertGt(psmV2.maxRedeemOrder(user1), 0, "exempt quote should clear the minimum");
        _nonExempt(FEE);
        assertEq(psmV2.maxRedeemOrder(user1), 0, "fee-net below the PSM minimum should quote 0");
    }

    // A balance whose gross exceeds syzUSD's per-window redeem limit is capped to that limit; a single
    // order above the limit could never settle in any window.
    function test_MaxRedeemOrder_CappedByInnerThrottleLimit() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _setStyzRedeemThrottle(500e18, type(uint256).max);
        uint256 max = psmV2.maxRedeemOrder(user1);
        assertLt(max, styzV3.balanceOf(user1), "cap should bind below the balance");
        assertLe(styzV3.convertToAssets(max), 500e18, "capped gross exceeds the throttle limit");
    }

    // Granting the PSM syzUSD's throttle exemption skips the cap: the full balance is quoted.
    function test_MaxRedeemOrder_ThrottleExemptSkipsCap() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _setStyzRedeemThrottle(500e18, type(uint256).max);
        _grantPsmStyzThrottleExempt();
        assertEq(psmV2.maxRedeemOrder(user1), styzV3.balanceOf(user1), "exempt PSM should skip the cap");
    }

    // Clears every floor and the limit: the full balance is quoted and is orderable.
    function test_MaxRedeemOrder_FullBalance_WhenClear() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        uint256 max = psmV2.maxRedeemOrder(user1);
        assertEq(max, styzV3.balanceOf(user1), "no floor or cap binds, so the full balance is orderable");
        vm.prank(user1);
        psmV2.createRedeemOrder(max, user1, user1);
        assertEq(psmV2.pendingOrderCount(), 1, "the quoted maximum was not orderable");
    }

    // The cap's promise: a capped order actually fills under a finite inner throttle, not merely that
    // its gross conversion is within the limit.
    function test_MaxRedeemOrder_CappedOrderFills() public {
        _deposit(user1, 1_000e6);
        vm.roll(block.number + 1);
        _setStyzRedeemThrottle(500e18, type(uint256).max);

        uint256 max = psmV2.maxRedeemOrder(user1);
        assertLt(max, styzV3.balanceOf(user1), "cap should bind below the balance");

        vm.prank(user1);
        uint256 orderId = psmV2.createRedeemOrder(max, user1, user1);

        uint256 balanceBefore = asset.balanceOf(user1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(orderFiller);
        psmV2.fillRedeemOrders(0, ids);

        assertEq(psmV2.pendingOrderCount(), 0, "the capped order was not filled");
        assertGt(asset.balanceOf(user1), balanceBefore, "the filled order paid nothing");
    }

    // The inner floor uses the fee-net value, not the gross: a minimum between gross and fee-net quotes
    // 0 only once the PSM stops being fee-exempt.
    function test_MaxRedeemOrder_InnerFloorIsFeeAware_NonExempt() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);

        vm.startPrank(admin);
        styzV3.grantRole(FEE_MANAGER_ROLE, admin);
        styzV3.setInstantRedeemFee(FEE);
        vm.stopPrank();

        uint256 shares = styzV3.balanceOf(user1);
        assertLt(styzV3.previewRedeem(shares), styzV3.convertToAssets(shares), "fixture: fee should reduce inner net");

        _setStyzMinWithdraw(styzV3.convertToAssets(shares)); // at the gross boundary: above the fee-net value
        vm.prank(limitManager);
        psmV2.setMinWithdraw(0); // PSM minimum not binding

        assertGt(psmV2.maxRedeemOrder(user1), 0, "exempt inner net equals gross and clears the floor");
        _nonExempt(FEE);
        assertEq(psmV2.maxRedeemOrder(user1), 0, "fee-aware inner floor should quote 0");
    }
}
