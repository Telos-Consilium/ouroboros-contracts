// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuOrderBookDefinitions, Order} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuProtoDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {
    BURNER_ROLE,
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    ORDER_FILLER_ROLE,
    POOL_MANAGER_ROLE,
    REDEEMER_ROLE,
    RESTRICTION_MANAGER_ROLE
} from "./helpers/TestRoles.sol";
import {Vm} from "forge-std/Vm.sol";

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
        yzilp.grantRole(DISTRIBUTOR_ROLE, admin);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
        _approve(other, address(yzilp));
    }

    // A pending order cannot be filled after the owner's REDEEMER_ROLE is revoked under redeem restriction.
    function test_FillRedeemOrder_Revert_OwnerRedeemerRevoked() public {
        vm.prank(user);
        uint256 shares = yzilp.deposit(1_000e6, user);

        vm.startPrank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        yzilp.grantRole(RESTRICTION_MANAGER_ROLE, admin);
        yzilp.setIsRedeemRestricted(true);
        yzilp.grantRole(REDEEMER_ROLE, user);
        vm.stopPrank();

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(shares, user, user);

        vm.prank(admin);
        yzilp.revokeRole(REDEEMER_ROLE, user);

        asset.mint(filler, 1_000e6);
        _approve(filler, address(yzilp));
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(IYuzuOrderBookDefinitions.OrderOwnerNotRedeemer.selector, orderId, user));
        yzilp.fillRedeemOrder(orderId);
    }

    // --- entry closure with unresolved zero-supply accounting ---

    function test_Entry_SupplyZeroTotalAssetsNonzero_IsClosed() public {
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 1, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.totalSupply(), 0);
        assertEq(yzilp.totalAssets(), 1);
        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user, 100e6, 0));
        yzilp.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxMint.selector, user, 100e18, 0));
        yzilp.mint(100e18, user);

        assertEq(yzilp.balanceOf(user), 0);
        assertEq(asset.balanceOf(user), 10_000_000e6);
    }

    // --- zero-supply entry closure and pool-manager resolution ---

    function test_LastShareFill_ClosesEntryUntilPoolManagerResolves() public {
        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 100e6, 0);
        yzilp.endPoolUpdate();
        yzilp.distribute(700e6, 7 days);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        vm.stopPrank();

        uint256 distributionStart = block.timestamp;
        vm.warp(distributionStart + 1 days);
        assertEq(yzilp.netDistributedSinceUpdate(), 100e6);
        assertEq(yzilp.totalAssets(), 200e6);

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(shares, user, user);

        asset.mint(filler, 1_000e6);
        _approve(filler, address(yzilp));
        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        Order memory order = yzilp.getRedeemOrder(orderId);
        assertEq(order.assets, 200e6);
        assertEq(yzilp.totalSupply(), 0);
        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.netDistributedSinceUpdate(), 0);
        assertEq(yzilp.totalAssets(), 0);
        assertEq(yzilp.maxDeposit(other), 0);
        assertEq(yzilp.maxMint(other), 0);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, other, 100e6, 0));
        yzilp.deposit(100e6, other);

        vm.startPrank(admin);
        yzilp.terminateDistribution();
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 0, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.lastDistributedAmount(), 0);
        assertEq(yzilp.lastDistributionPeriod(), 0);
        assertEq(yzilp.lastDistributionTimestamp(), 0);
        vm.warp(distributionStart + 7 days);
        assertEq(yzilp.netDistributedSinceUpdate(), 0);
        assertEq(yzilp.totalAssets(), 0);

        vm.prank(other);
        uint256 newShares = yzilp.deposit(100e6, other);
        assertEq(newShares, 100e18);
        assertEq(yzilp.totalAssets(), 100e6);
        assertEq(yzilp.convertToAssets(newShares), 100e6);
    }

    function test_FullBurn_ClosesEntryUntilPoolManagerResolves() public {
        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 100e6, 0);
        yzilp.endPoolUpdate();
        yzilp.distribute(70e6, 7 days);
        yzilp.grantRole(BURNER_ROLE, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        yzilp.burn(shares);

        assertEq(yzilp.totalSupply(), 0);
        assertEq(yzilp.netDistributedSinceUpdate(), 10e6);
        assertEq(yzilp.lastDistributedAmount(), 70e6);
        assertEq(yzilp.lastDistributionPeriod(), 7 days);
        assertEq(yzilp.totalAssets(), 110e6);
        assertEq(yzilp.maxDeposit(other), 0);
        assertEq(yzilp.maxMint(other), 0);

        vm.startPrank(admin);
        yzilp.terminateDistribution();
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 0, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.netDistributedSinceUpdate(), 0);
        assertEq(yzilp.totalAssets(), 0);
        assertGt(yzilp.maxDeposit(other), 0);
        assertGt(yzilp.maxMint(other), 0);
    }

    // At zero supply, depositing the reported maximum must not mint past a cap that is not aligned
    // to the share-per-asset rate; the maximum rounds down.
    function test_MaxDeposit_ZeroSupply_DoesNotExceedNonAlignedCap() public {
        uint256 cap = 1e18 + 7e11; // not a multiple of the 1e12 share-per-asset rate
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setSupplyCap(cap);
        vm.stopPrank();

        assertEq(yzilp.totalSupply(), 0);
        uint256 maxAssets = yzilp.maxDeposit(user);
        assertGt(maxAssets, 0);
        assertLe(yzilp.previewDeposit(maxAssets), cap, "zero-supply maxDeposit must not breach the cap");

        vm.prank(user);
        yzilp.deposit(maxAssets, user);
        assertLe(yzilp.totalSupply(), cap, "depositing the maximum must not breach the cap");
    }

    function test_PartialBurn_PreservesDistribution() public {
        vm.prank(user);
        yzilp.deposit(100e6, user);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 100e6, 0);
        yzilp.endPoolUpdate();
        yzilp.distribute(70e6, 7 days);
        yzilp.grantRole(BURNER_ROLE, user);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vm.prank(user);
        yzilp.burn(50e18);

        assertEq(yzilp.totalSupply(), 50e18);
        assertEq(yzilp.netDistributedSinceUpdate(), 10e6);
        assertEq(yzilp.lastDistributedAmount(), 70e6);
        assertEq(yzilp.lastDistributionPeriod(), 7 days);
        assertGt(yzilp.lastDistributionTimestamp(), 0);
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
    // backs the shares, so deposits price against total assets and existing holders keep their
    // per-share value.
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
        yzilp.distribute(2000e6, 1 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days + 1);

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

    // --- management fee on a deposit into an empty pool ---

    // A deposit into an empty pool is credited in last-update pool units, so the management fee
    // that the enlarged poolSize then accrues for the whole period since that update is already
    // priced into the credit. At deposit time the shares are worth what was paid, whether the rate
    // went live before or after the seed.
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

    function test_Bootstrap_ActivateBeforeSeed_DepositIsFeeNeutral() public {
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

        // The credited units bear fee only from now, so the year already elapsed does not reach
        // the deposit
        assertApproxEqAbs(yzilp.totalAssets(), 1000e6, 1);
        assertApproxEqAbs(yzilp.convertToAssets(shares), 1000e6, 1);
        assertEq(yzilp.poolSize(), 1000e6);
    }

    // --- deposit pricing on a near-empty pool with an armed yield rate ---

    // The credit divides the deposit by the accrual a pool unit carries over the elapsed period.
    // That accrual is derived from the yield and management rates, so it holds even when the pool
    // is small enough for its own accrued yield to floor to zero, and the deposit earns no yield
    // for the period before it entered.
    function test_Deposit_DustPoolWithArmedYield_CreatesNoValue() public {
        vm.prank(user);
        yzilp.deposit(1000, user);
        _promoteIlpFees(10_000); // 1% per day, the protocol maximum

        // Just under a tenth of a day: the dust pool's own accrued yield floors to zero
        vm.warp(block.timestamp + 8639);
        assertEq(yzilp.totalAssets(), 1000);

        vm.prank(other);
        uint256 shares = yzilp.deposit(1_000_000e6, other);

        assertLe(yzilp.convertToAssets(shares), 1_000_000e6, "deposit created value against a dust pool");
        assertApproxEqAbs(yzilp.convertToAssets(shares), 1_000_000e6, 1, "deposit lost material value");
    }

    // The pricing holds however long the pool is left near zero before the deposit arrives.
    function test_Deposit_DustPoolLeftStaleForDays_CreatesNoValue() public {
        vm.prank(user);
        yzilp.deposit(10, user);
        _promoteIlpFees(10_000);

        vm.warp(block.timestamp + 7 days);
        assertEq(yzilp.totalAssets(), 10);

        vm.prank(other);
        uint256 shares = yzilp.deposit(1_000_000e6, other);

        assertLe(yzilp.convertToAssets(shares), 1_000_000e6, "deposit created value against a stale dust pool");
        assertApproxEqAbs(yzilp.convertToAssets(shares), 1_000_000e6, 1, "deposit lost material value");
    }

    // --- deposit pricing when the pool is zero under a live management fee ---

    // With poolSize zero the credit still carries the management premium: the units it adds begin
    // accruing the fee for the whole period since the last update the moment they land.
    function test_Deposit_PoolZeroUnderManagementFee_MintsAtUnchangedSharePrice() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year, the protocol maximum
        _promoteIlpFees(0);
        _reportIlpPool(0); // the pool is marked to zero against live supply

        vm.prank(admin);
        yzilp.distribute(500e6, 7 days);
        vm.warp(block.timestamp + 365 days);

        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.totalAssets(), 500e6);
        uint256 priceBefore = yzilp.convertToAssets(1e18);
        uint256 holderValueBefore = yzilp.convertToAssets(yzilp.balanceOf(user));

        vm.prank(other);
        uint256 shares = yzilp.deposit(500e6, other);

        assertEq(yzilp.poolSize(), 500e6, "credit was not the deposited value");
        assertApproxEqAbs(yzilp.totalAssets(), 1000e6, 1, "management fee charged retroactively");
        assertApproxEqAbs(yzilp.convertToAssets(1e18), priceBefore, 1, "share price moved");
        assertApproxEqAbs(yzilp.convertToAssets(shares), 500e6, 1, "depositor lost value");
        assertApproxEqAbs(
            yzilp.convertToAssets(yzilp.balanceOf(user)), holderValueBefore, 1, "existing holder lost value"
        );
    }

    // --- deposit value survives the next pool update ---

    // The management fee accrues over the time each pool unit was actually in the pool, so an
    // update that reports the assets the pool truly holds settles only the fee the pre-existing
    // pool owed. A deposit made part-way through the period keeps its value across that update.
    function test_Deposit_ThenTruthfulUpdate_PreservesDepositorValue() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        _promoteIlpFees(0);

        vm.warp(block.timestamp + 365 days);
        assertEq(yzilp.totalAssets(), 900e6, "seed did not accrue a year of fee");

        vm.prank(other);
        uint256 shares = yzilp.deposit(1000e6, other);
        assertApproxEqAbs(yzilp.convertToAssets(shares), 1000e6, 1, "deposit mispriced on entry");

        // The pool truly holds the 1000e6 seed plus the 1000e6 just deposited
        _reportIlpPool(2000e6);

        assertApproxEqAbs(yzilp.convertToAssets(shares), 1000e6, 1, "update charged the deposit for time before entry");
        assertApproxEqAbs(yzilp.totalAssets(), 1900e6, 1, "update moved total assets");
        assertEq(yzilp.cumulativeManagementFees(), 100e6, "fee booked beyond the seed's own accrual");
    }

    // The same holds when the deposit is the pool's only content, where the whole period elapsed
    // before it arrived.
    function test_Bootstrap_DepositThenTruthfulUpdate_ChargesNoFee() public {
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _reportIlpPool(0); // promote the rate against an empty pool

        vm.warp(block.timestamp + 365 days);

        vm.prank(user);
        uint256 shares = yzilp.deposit(1000e6, user);
        _reportIlpPool(1000e6);

        assertApproxEqAbs(yzilp.convertToAssets(shares), 1000e6, 1, "deposit bore fee accrued before entry");
        assertEq(yzilp.cumulativeManagementFees(), 0, "fee booked against an empty pool");
    }

    // --- management fee is proportional to time spent in the pool ---

    // Credited units begin accruing management fee when they land, so the fee realized at the next
    // update covers the pre-existing pool for the whole period and the deposit only for the part of
    // the period that followed it.
    function _assertProRataFee(uint256 daysBeforeDeposit, uint256 expectedFee) internal {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        _promoteIlpFees(0);
        assertEq(yzilp.cumulativeManagementFees(), 0, "fee booked before the rate went live");

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + daysBeforeDeposit * 1 days);
        vm.prank(other);
        yzilp.deposit(1000e6, other);

        vm.warp(start + 365 days);
        _reportIlpPool(2000e6);

        assertEq(yzilp.cumulativeManagementFees(), expectedFee, "fee not proportional to time in the pool");
    }

    // Present for the last 80% of the year: 10% of 1000e6 for the full year plus 80% of that again
    function test_ManagementFee_DepositEarlyInPeriod_ChargedForMostOfIt() public {
        _assertProRataFee(73, 180e6);
    }

    // Present for the last 60%
    function test_ManagementFee_DepositMidPeriod_ChargedForRemainder() public {
        _assertProRataFee(146, 160e6);
    }

    // Present for the last 20%
    function test_ManagementFee_DepositLateInPeriod_ChargedForLittle() public {
        _assertProRataFee(292, 120e6);
    }

    // Present for none of it: only the pre-existing pool is charged
    function test_ManagementFee_DepositAtPeriodEnd_ChargedForNone() public {
        _assertProRataFee(365, 100e6);
    }

    // Two deposits in one period each bear fee from their own arrival, so the accumulator sums
    // rather than tracking only the most recent credit.
    function test_ManagementFee_TwoDepositsInOnePeriod_EachChargedFromArrival() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promoteIlpFees(0);
        uint256 start = yzilp.lastPoolUpdateTimestamp();

        vm.warp(start + 146 days); // present for the last 60% of the year
        vm.prank(other);
        yzilp.deposit(1000e6, other);

        vm.warp(start + 292 days); // present for the last 20%
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.warp(start + 365 days);
        _reportIlpPool(3000e6);

        // 10% of 1000e6 for the whole year, plus 60% and 20% of 1000e6 each
        assertEq(yzilp.cumulativeManagementFees(), 180e6, "deposits did not each accrue from arrival");
    }

    // An order fill removes a uniform fraction of every pool unit's fee claim, so the credited
    // fee-time it carries shrinks by that same fraction. A deposit either side of the fill keeps
    // its value, and the fill itself leaves the share price untouched.
    function test_ManagementFee_DepositFillDepositUpdate_KeepsBasisExact() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promoteIlpFees(0);
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        uint256 start = yzilp.lastPoolUpdateTimestamp();

        vm.warp(start + 146 days);
        vm.prank(other);
        uint256 otherShares = yzilp.deposit(1000e6, other);

        vm.warp(start + 219 days);
        uint256 poolBefore = yzilp.poolSize();
        uint256 csBefore = yzilp.creditSecondsSinceUpdate();
        uint256 priceBefore = yzilp.convertToAssets(1e18);
        assertGt(csBefore, 0, "no credited fee-time to scale");

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(400e18, user, user);
        asset.mint(filler, 2_000e6);
        _approve(filler, address(yzilp));
        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        assertLt(yzilp.poolSize(), poolBefore, "fill did not reduce the pool");
        assertEq(
            yzilp.creditSecondsSinceUpdate(),
            csBefore * yzilp.poolSize() / poolBefore,
            "credited fee-time did not scale with the pool"
        );
        assertEq(yzilp.convertToAssets(1e18), priceBefore, "fill moved the share price");

        vm.warp(start + 365 days);
        vm.prank(other);
        yzilp.deposit(500e6, other);
        _reportIlpPool(yzilp.poolSize());

        // The seed bears a full year on the units that survived the fill; the day-146 deposit bears
        // the 219 days that followed it; the day-365 deposit bears nothing.
        assertEq(yzilp.cumulativeManagementFees(), 128_653_062, "fee is not the time-weighted amount");
        assertEq(yzilp.convertToAssets(otherShares), 938_775_509, "holder bore other than its own accrual");
    }

    // The fill floors the scaled credit, so division dust shrinks the credited claim and enlarges
    // the fee basis: the booked fee can only round up from the exact rational amount, never down
    // in the depositor's favour. The dust is under one pool-unit-second, so an upward shift needs
    // a fee ceiling boundary inside that span; this fixture sits off any boundary and shows the
    // common case, a booked fee identical whichever way the credit rounds.
    function test_ManagementFee_FillCreditFloorDust_LeavesBookedFeeUnchanged() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);

        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        _promoteIlpFees(0);
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        uint256 start = yzilp.lastPoolUpdateTimestamp();

        // An odd second count and a prime-sized deposit keep the credited fee-time from sharing a
        // factor with the pool, so the scaling below truncates.
        vm.warp(start + 100 days + 1);
        vm.prank(other);
        yzilp.deposit(999_999_937, other);

        vm.warp(start + 200 days);
        uint256 poolBefore = yzilp.poolSize();
        uint256 csBefore = yzilp.creditSecondsSinceUpdate();

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(400e18, user, user);
        asset.mint(filler, 2_000e6);
        _approve(filler, address(yzilp));
        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        uint256 poolAfter = yzilp.poolSize();
        assertGt(csBefore * poolAfter % poolBefore, 0, "fixture: scaling divides exactly, dust untested");
        uint256 csFloor = csBefore * poolAfter / poolBefore;
        assertEq(yzilp.creditSecondsSinceUpdate(), csFloor, "credit did not floor");

        vm.warp(start + 365 days);
        _reportIlpPool(yzilp.poolSize());

        // The fee recomputed at the floored credit and one unit-second above it brackets the exact
        // rational credit; both agree here, so the dust does not move the fee in this fixture.
        uint256 denominator = 1e6 * 365 days;
        uint256 feeAtFloor = ((poolAfter * 365 days - csFloor) * 100_000 + denominator - 1) / denominator;
        uint256 feeAtCeil = ((poolAfter * 365 days - (csFloor + 1)) * 100_000 + denominator - 1) / denominator;
        assertEq(feeAtFloor, feeAtCeil, "fixture: credit dust landed on a fee ceiling boundary");
        assertEq(yzilp.cumulativeManagementFees(), feeAtFloor, "booked fee is not the bracketed amount");
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

    function _seedPoolWithLiveFee() internal returns (uint256 start) {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        _promoteIlpFees(0);
        start = yzilp.lastPoolUpdateTimestamp();
    }

    function _assertNoShortfallLogged() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ManagementFeeShortfall.selector, "shortfall signalled on a covered fee");
        }
    }

    // The counters record realized amounts. A loss mark below the accrued fee books only the
    // reported value, floors the net pool at zero, and signals the unrealized remainder.
    function test_CumulativeManagementFees_DeepLossMark_BooksOnlyRealized() public {
        uint256 start = _seedPoolWithLiveFee();
        vm.warp(start + 365 days); // 100e6 accrued

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit RealizedManagementFee(50e6, 50e6);
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit ManagementFeeShortfall(100e6, 50e6, 0);
        yzilp.updatePool(1000e6, 50e6, 0); // marked below the accrued fee
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.cumulativeManagementFees(), 50e6, "booked more than the mark could realize");
        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.totalAssets(), 0);

        // A further update with nothing accrued leaves the counters unchanged
        _reportIlpPool(0);
        assertEq(yzilp.cumulativeManagementFees(), 50e6);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }

    // Accrued fee within the reported value books in full and signals nothing.
    function test_UpdatePool_AccruedFeeBelowMark_BooksAccruedWithoutShortfall() public {
        uint256 start = _seedPoolWithLiveFee();
        vm.warp(start + 365 days); // 100e6 accrued

        vm.recordLogs();
        _reportIlpPool(150e6);

        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.poolSize(), 50e6);
        _assertNoShortfallLogged();
    }

    // Accrued fee exactly at the reported value realizes completely, so nothing is signalled.
    function test_UpdatePool_AccruedFeeAtMark_BooksAllWithoutShortfall() public {
        uint256 start = _seedPoolWithLiveFee();
        vm.warp(start + 365 days);

        vm.recordLogs();
        _reportIlpPool(100e6);

        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.poolSize(), 0);
        assertEq(yzilp.totalAssets(), 0);
        _assertNoShortfallLogged();
    }

    // One unit below the accrued fee realizes all but that unit.
    function test_UpdatePool_AccruedFeeJustAboveMark_SignalsOneUnitShortfall() public {
        uint256 start = _seedPoolWithLiveFee();
        vm.warp(start + 365 days);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit ManagementFeeShortfall(100e6, 100e6 - 1, 0);
        yzilp.updatePool(1000e6, 100e6 - 1, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        assertEq(yzilp.cumulativeManagementFees(), 100e6 - 1);
        assertEq(yzilp.poolSize(), 0);
    }

    // A shortfall leaves nothing above the benchmark: no performance fee books and the
    // high-water mark holds.
    function test_UpdatePool_ShortfallWithActivePerformanceFee_BooksNoPerfAndKeepsHWM() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.startPrank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        yzilp.setPendingPerformanceFee(200_000);
        vm.stopPrank();
        _promoteIlpFees(0);
        uint256 hwmBefore = yzilp.highWaterMark();
        assertGt(hwmBefore, 0, "fixture: no benchmark to hold");

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + 365 days);
        _reportIlpPool(50e6);

        assertEq(yzilp.cumulativeManagementFees(), 50e6);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
        assertEq(yzilp.highWaterMark(), hwmBefore, "loss mark moved the benchmark");
    }

    // The unrealized remainder is not a debt: after recapitalization the next period books only
    // its own accrual.
    function test_UpdatePool_ShortfallNotCarried_NextPeriodBooksOwnAccrual() public {
        uint256 start = _seedPoolWithLiveFee();
        vm.warp(start + 365 days);
        _reportIlpPool(50e6); // accrued 100e6, realized 50e6
        assertEq(yzilp.cumulativeManagementFees(), 50e6);

        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 1000e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();

        uint256 start2 = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start2 + 365 days);
        _reportIlpPool(1000e6);

        assertEq(yzilp.cumulativeManagementFees(), 150e6, "shortfall carried into the next period");
    }

    // --- performance benchmark floor ---

    // A near-total loss marked before any benchmark-raising update cannot pull the benchmark
    // to the wrecked price: it is seeded at par, so the surviving value and the recovery back
    // to par bear no performance fee, and fee resumes only above par.
    function test_PerformanceFee_WreckBeforeFirstUpdate_RecoveryToParIsFeeFree() public {
        vm.prank(user);
        yzilp.deposit(1000e6, user);
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000); // 20%

        // The first update is the wreck; it also promotes the pending rate to live
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(1000e6, 100, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
        assertEq(yzilp.highWaterMark(), 1e6, "wreck displaced the seeded benchmark");

        _reportIlpPool(1000e6); // recovery to par
        assertEq(yzilp.cumulativePerformanceFees(), 0, "recovery to par charged performance fee");
        assertEq(yzilp.highWaterMark(), 1e6);

        _reportIlpPool(1100e6); // the first genuine gain above par
        assertEq(yzilp.cumulativePerformanceFees(), 20e6, "fee is not 20% of the gain above par");
        assertEq(yzilp.highWaterMark(), 1_100_000);
    }
}
