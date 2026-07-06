// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {Order} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuProtoDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuILPV3PoolEdgeTest is
    YuzuV3TestBase,
    IYuzuIssuerDefinitions,
    IYuzuProtoDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions
{
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(other, 10_000_000e6);
        yzilp = _deployYuzuILPV3();

        vm.startPrank(admin);
        yzilp.grantRole(FEE_MANAGER_ROLE, feeManager);
        yzilp.grantRole(POOL_MANAGER_ROLE, admin);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
        _approve(other, address(yzilp));
    }

    // --- deposit pricing when supply is zero but poolSize is not ---

    // With zero supply the vault is fresh regardless of a residual poolSize (operator mark with
    // no shares out, or rounding dust after a full exit), so deposits mint at the 1:1 offset
    // rate instead of converting against the empty supply and minting nothing.
    function test_Deposit_SupplyZeroPoolNonzero_MintsAtOffsetRate() public {
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 1, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.totalSupply(), 0);
        assertEq(yzilp.poolSize(), 1);
        assertGt(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.previewDeposit(100e6), 100e18);

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);

        assertEq(shares, 100e18);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(balBefore - asset.balanceOf(user), 100e6);
    }

    // The mirrored path prices freshness off totalSupply == 0 too, so mint agrees with deposit
    // at the 1:1 offset rate.
    function test_Mint_SupplyZeroPoolNonzero_MintsAtOffsetRate() public {
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 1, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.prank(user);
        uint256 paid = yzilp.mint(100e18, user);

        assertEq(paid, 100e6);
        assertEq(yzilp.balanceOf(user), 100e18);
    }

    // --- free-mint griefing when the pool is marked to zero against live supply ---

    // With supply outstanding and total assets marked to zero, previewMint prices any share
    // count at zero assets. Entry must be closed in that state: otherwise shares minted for
    // free would capture value pro rata as soon as a later update marks the pool back up.
    function test_Entry_SupplyNonzeroTotalAssetsZero_IsClosed() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        // Total loss mark
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 0, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.totalAssets(), 0);
        assertGt(yzilp.totalSupply(), 0);
        assertEq(yzilp.previewMint(1_000_000e18), 0);

        // Both entry doors are closed
        assertEq(yzilp.maxDeposit(other), 0);
        assertEq(yzilp.maxMint(other), 0);

        vm.prank(other);
        vm.expectRevert(ZeroTotalAssets.selector);
        yzilp.mint(1_000_000e18, other);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IYuzuIssuerDefinitions.ExceededMaxDeposit.selector, other, 100e6, 0));
        yzilp.deposit(100e6, other);
    }

    // --- deposit pricing when poolSize is zero but distributed assets remain ---

    // A zeroed pool bucket with live supply is not a fresh vault: the distribution bucket still
    // backs the shares, so deposits price against total assets rather than minting at par and
    // moving value between the depositor and the existing holders.
    function test_Deposit_PoolZeroWithDistributions_MintsAtDistributionBackedPrice() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        // Mark the pool bucket to zero, then vest a distribution on top of it
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 0, 0);
        yzilp.endPoolUpdate();
        yzilp.distribute(2000e6, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 2);

        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.totalAssets(), 2000e6);
        assertEq(yzilp.totalSupply(), 1000e18);
        // True share price is 2.0, so 100e6 assets mint 50e18 shares
        assertEq(yzilp.previewDeposit(100e6), 50e18);

        uint256 holderValueBefore = yzilp.convertToAssets(yzilp.balanceOf(user));

        vm.prank(other);
        uint256 shares = yzilp.deposit(100e6, other);
        assertEq(shares, 50e18);

        // The depositor's claim matches the assets paid and existing holders keep their value
        uint256 depositorValue = yzilp.convertToAssets(shares);
        assertApproxEqAbs(depositorValue, 100e6, 1);
        assertApproxEqAbs(yzilp.convertToAssets(yzilp.balanceOf(user)), holderValueBefore, 1);
    }

    // --- share price continuity across a gross-marked update ---

    // An update whose newPoolSize equals the current gross value (pool plus accrued yield plus
    // net distributions) crystallizes the accrued fees without moving the fee-net share price.
    function test_UpdatePool_GrossNeutralMark_PreservesTotalAssets() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.startPrank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        yzilp.setPendingPerformanceFee(200_000); // 20%
        vm.stopPrank();
        _promoteIlpFees(10_000); // 1% per day linear yield

        vm.prank(admin);
        yzilp.distribute(50e6, 1 days);
        vm.warp(block.timestamp + 10 days);

        uint256 pool = yzilp.poolSize();
        uint256 elapsed = block.timestamp - yzilp.lastPoolUpdateTimestamp();
        uint256 gross =
            pool + pool * yzilp.dailyLinearYieldRatePpm() * elapsed / (1e6 * 1 days) + yzilp.netDistributedSinceUpdate();
        assertEq(gross, 1150e6);

        uint256 totalBefore = yzilp.totalAssets();

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(pool, gross, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertApproxEqAbs(yzilp.totalAssets(), totalBefore, 2, "gross-neutral update moved the fee-net value");
        assertEq(
            yzilp.cumulativeManagementFees() + yzilp.cumulativePerformanceFees() + yzilp.totalAssets(),
            gross,
            "crystallized fees and net pool do not add back to the gross mark"
        );
    }

    // --- deposit closure boundary under accrued management fee ---

    // Deposits close exactly when the accrued management fee reaches the pool bucket's gross
    // value. With zero yield and the 10% annual rate, that is ten years of accrual.
    function test_MaxDeposit_ClosesExactlyAtFeeErosionBoundary() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promoteIlpFees(0);

        uint256 lastUpdate = yzilp.lastPoolUpdateTimestamp();

        vm.warp(lastUpdate + 3650 days - 1 days);
        assertGt(yzilp.maxDeposit(user), 0);
        assertGt(yzilp.maxMint(user), 0);

        vm.warp(lastUpdate + 3650 days);
        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user, 100e6, 0));
        yzilp.deposit(100e6, user);
    }

    // --- retroactive management fee on a deposit into an empty pool ---

    // A deposit into an empty pool is credited without a management-fee gross-up, so once it
    // lands in poolSize the fee formula charges it for the whole period since the last update,
    // including time before the deposit existed. Seeding before the rate goes live avoids it.
    function test_Bootstrap_SeedBeforeActivation_DepositIsFeeNeutral() public {
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);

        vm.prank(user);
        yzilp.deposit(1000e6, user);
        assertEq(yzilp.totalAssets(), 1000e6);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.managementFeeRatePpm(), 100_000);
        assertEq(yzilp.totalAssets(), 1000e6);
    }

    function test_Bootstrap_ActivateBeforeSeed_FirstDepositBearsRetroactiveFee() public {
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 0, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
        assertEq(yzilp.managementFeeRatePpm(), 100_000);

        vm.warp(block.timestamp + 365 days);

        vm.prank(user);
        uint256 shares = yzilp.deposit(1000e6, user);
        assertEq(shares, 1000e18);

        // A year of retroactive fee accrual lands on the deposit the moment it is credited
        assertEq(yzilp.totalAssets(), 900e6);
        assertEq(yzilp.convertToAssets(shares), 900e6);
    }

    // --- order filled across a pool update ---

    // An order locks its fee rate at creation but prices assets at fill time. A rate change and
    // a pool repricing between creation and fill must settle at the new price with the old rate.
    // The withheld fee is never transferred to the fee receiver on the order path: the filler
    // pays only the net amount, so the fee value implicitly accrues to the treasury side.
    function test_OrderFill_AcrossUpdate_FillPriceCreationFeeRate() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.prank(feeManager);
        yzilp.setRedeemOrderFee(10_000); // 1%, locked into the order at creation

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(100e18, user, user);

        vm.prank(feeManager);
        yzilp.setRedeemOrderFee(50_000); // 5%, must not apply to the existing order
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1200e6, 0); // share price 1.0 -> 1.2
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        asset.mint(filler, 1_000e6);
        _approve(filler, address(yzilp));
        uint256 fillerBalBefore = asset.balanceOf(filler);

        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        // 100e18 shares at the 1.2 fill price are 120e6 gross; 1% fee on total, ceil-rounded
        uint256 expectedFee = (uint256(120e6) * 10_000 + 1_009_999) / 1_010_000;
        uint256 expectedNet = 120e6 - expectedFee;
        Order memory order = yzilp.getRedeemOrder(orderId);
        assertEq(order.assets, expectedNet);
        assertEq(fillerBalBefore - asset.balanceOf(filler), expectedNet);
        assertEq(asset.balanceOf(feeReceiver), 0);

        vm.prank(user);
        yzilp.finalizeRedeemOrder(orderId);
        assertEq(asset.balanceOf(user), 10_000_000e6 - 1000e6 + expectedNet);
    }

    // --- cumulative fee counters ---

    // The counters record the accrued formula amount at each update. In a loss mark below the
    // accrued fee, the net pool floors at zero and the counter still books the full accrual,
    // exceeding the value the haircut captured from holders.
    function test_CumulativeManagementFees_DeepLossMark_BooksFormulaAmount() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promoteIlpFees(0);

        vm.warp(block.timestamp + 365 days); // 100e6 accrued

        _reportIlpPool(50e6); // marked below the accrued fee

        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.totalAssets(), 0);

        // A further update with nothing accrued leaves the counters unchanged
        _reportIlpPool(0);
        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }
}
