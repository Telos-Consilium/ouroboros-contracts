// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IYuzuILPDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions
} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {DISTRIBUTOR_ROLE, FEE_MANAGER_ROLE, POOL_MANAGER_ROLE, PRICE_GUARD_MANAGER_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuILPV3PriceGuardTest is
    YuzuV3TestBase,
    IYuzuILPDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions
{
    uint256 internal constant MIN_PRICE = 950_000;
    uint256 internal constant MAX_PRICE = 1_200_000;

    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        yzilp = _deployYuzuILPV3();

        vm.startPrank(admin);
        yzilp.grantRole(POOL_MANAGER_ROLE, poolManager);
        yzilp.grantRole(DISTRIBUTOR_ROLE, poolManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
    }

    // --- helpers ---

    function _seedPool() internal {
        vm.prank(user);
        yzilp.deposit(100e6, user);
    }

    // --- tighter yield cap (applies to every updatePool path) ---

    function test_UpdatePool_AtYieldCap() public {
        _seedPool();
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 100e6, 10_000);
        vm.stopPrank();
        assertEq(yzilp.dailyLinearYieldRatePpm(), 10_000);
    }

    function test_UpdatePool_Revert_OverYieldCap() public {
        _seedPool();
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, 10_001));
        yzilp.updatePool(100e6, 100e6, 10_001);
        vm.stopPrank();
    }

    function test_UpdatePool_Revert_YieldAboveV3Ceiling() public {
        // 500_000 ppm (50%/day) is within the inherited 1e6 bound but exceeds the 10_000 ppm V3 ceiling
        _seedPool();
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, 500_000));
        yzilp.updatePool(100e6, 100e6, 500_000);
        vm.stopPrank();
    }

    // --- bounded updatePool ---

    function test_BoundedUpdatePool_InBand() public {
        _seedPool();
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 110e6, 0, MIN_PRICE, MAX_PRICE); // price 1.1e6
        yzilp.endPoolUpdate();
        vm.stopPrank();
        assertEq(yzilp.poolSize(), 110e6);
    }

    function test_BoundedUpdatePool_Revert_AboveBand() public {
        _seedPool();
        vm.prank(poolManager);
        yzilp.startPoolUpdate();
        // 1100e6 implies a price of 11e6.
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooHigh.selector, 11_000_000, MAX_PRICE));
        yzilp.updatePool(100e6, 1100e6, 0, MIN_PRICE, MAX_PRICE);
    }

    function test_BoundedUpdatePool_Revert_BelowBand() public {
        _seedPool();
        vm.prank(poolManager);
        yzilp.startPoolUpdate();
        // 50e6 implies a price of 0.5e6, below the band
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooLow.selector, 500_000, MIN_PRICE));
        yzilp.updatePool(100e6, 50e6, 0, MIN_PRICE, MAX_PRICE);
    }

    function test_BoundedUpdatePool_Revert_OverYieldCapBeforeBand() public {
        // The yield cap is enforced before the band, so a bad rate reverts with InvalidYield
        _seedPool();
        vm.prank(poolManager);
        yzilp.startPoolUpdate();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, 10_001));
        yzilp.updatePool(100e6, 110e6, 10_001, MIN_PRICE, MAX_PRICE);
    }

    function test_BoundedUpdatePool_SkippedWhenNoSupply() public {
        // No deposit: supply is 0, so the band is not checked and any newPoolSize is accepted
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(0, 500e6, 0, 1_000_000, 1_000_000);
        vm.stopPrank();
        assertEq(yzilp.poolSize(), 500e6);
    }

    // --- bounded distribute ---

    function test_BoundedDistribute_InBand() public {
        _seedPool();
        // Projected end price: (100e6 + 10e6)/supply = 1.1e6
        vm.prank(poolManager);
        yzilp.distribute(10e6, 1 days, MIN_PRICE, MAX_PRICE);
        assertEq(yzilp.lastDistributedAmount(), 10e6);
    }

    function test_BoundedDistribute_Revert_AboveBand() public {
        _seedPool();
        // 1000e6 distributed implies an end price of 11e6.
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooHigh.selector, 11_000_000, MAX_PRICE));
        yzilp.distribute(1000e6, 1 days, MIN_PRICE, MAX_PRICE);
    }

    // --- bounded distribute nets the performance fee ---

    // Arms the rate and benchmarks the current value: pool 100e6, supply 100e18, benchmark 1e6.
    function _armPerformanceFee(uint256 ratePpm) internal {
        vm.prank(admin);
        yzilp.grantRole(FEE_MANAGER_ROLE, feeManager);
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(ratePpm);
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(yzilp.poolSize(), yzilp.poolSize(), 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
    }

    function _markPool(uint256 newPoolSize) internal {
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(yzilp.poolSize(), newPoolSize, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
    }

    // A distribution above the benchmark bears performance fee, and the floor evaluates the
    // fee-net projection: a minimum between net and gross end price rejects the distribution.
    function test_BoundedDistribute_Revert_NetBelowFloorFromPerformanceFee() public {
        _seedPool();
        _armPerformanceFee(200_000);
        // 10e6 above the benchmark bears 2e6 of fee: net 1.08e6, gross 1.1e6
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooLow.selector, 1_080_000, 1_090_000));
        yzilp.distribute(10e6, 1 days, 1_090_000, MAX_PRICE);
    }

    // Below the benchmark the distributed amount bears no fee and the projection is the gross
    // end value, accepted exactly at the floor.
    function test_BoundedDistribute_BelowBenchmark_ProjectsGross() public {
        _seedPool();
        _armPerformanceFee(200_000);
        _markPool(80e6); // benchmark stays 1e6
        vm.prank(poolManager);
        yzilp.distribute(10e6, 1 days, 900_000, MAX_PRICE); // projected end price exactly 0.9e6
        assertEq(yzilp.lastDistributedAmount(), 10e6);
    }

    // A distribution crossing the benchmark bears fee only on the slice above it: 30e6 onto an
    // 80e6 pool crosses the 100e6 benchmark by 10e6, so net is 110e6 less 20% of 10e6.
    function test_BoundedDistribute_CrossingBenchmark_FeeOnSliceAbove() public {
        _seedPool();
        _armPerformanceFee(200_000);
        _markPool(80e6);
        vm.prank(poolManager);
        yzilp.distribute(30e6, 1 days, 1_080_000, MAX_PRICE); // accepted exactly at the net price
        assertEq(yzilp.lastDistributedAmount(), 30e6);
    }

    function test_BoundedDistribute_Revert_CrossingBenchmark_OneAboveNet() public {
        _seedPool();
        _armPerformanceFee(200_000);
        _markPool(80e6);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooLow.selector, 1_080_000, 1_080_001));
        yzilp.distribute(30e6, 1 days, 1_080_001, MAX_PRICE);
    }

    // The cap also evaluates the fee-net projection: a gross end value above the cap passes when
    // the value holders retain is within it, and rejects when it is not.
    function test_BoundedDistribute_MaxAcceptsWhenNetWithinCap() public {
        _seedPool();
        _armPerformanceFee(200_000);
        vm.prank(poolManager);
        yzilp.distribute(10e6, 1 days, MIN_PRICE, 1_080_000); // net 1.08e6 at the cap, gross 1.1e6 above it
        assertEq(yzilp.lastDistributedAmount(), 10e6);
    }

    function test_BoundedDistribute_Revert_NetAboveCap() public {
        _seedPool();
        _armPerformanceFee(200_000);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooHigh.selector, 1_080_000, 1_070_000));
        yzilp.distribute(10e6, 1 days, MIN_PRICE, 1_070_000);
    }

    // With no management fee and fixed supply the projection is exact: an equal-min-max band at
    // the predicted net price accepts the distribution, and the live price lands on it once the
    // distribution has fully vested. The equal bounds also pin that both band checks evaluate
    // the same projected value.
    function test_Fuzz_BoundedDistribute_ProjectionMatchesEndOfVesting(uint256 assets, uint256 ratePpm, uint256 mark)
        public
    {
        assets = bound(assets, 1, 2_000e6);
        ratePpm = bound(ratePpm, 0, 500_000);
        mark = bound(mark, 1e6, 100e6); // at or below the benchmark value, so the benchmark stays 1e6

        _seedPool();
        _armPerformanceFee(ratePpm);
        _markPool(mark);

        uint256 endGross = mark + assets;
        uint256 aboveBenchmark = endGross > 100e6 ? endGross - 100e6 : 0;
        uint256 performanceFee = (aboveBenchmark * ratePpm + 1e6 - 1) / 1e6;
        uint256 expectedNet = endGross - performanceFee;
        uint256 expectedPrice = expectedNet * 1e18 / 100e18;

        vm.prank(poolManager);
        yzilp.distribute(assets, 1 days, expectedPrice, expectedPrice);

        uint256 start = block.timestamp;
        vm.warp(start + 1 days);
        assertEq(yzilp.totalAssets(), expectedNet, "realized end value diverged from the projection");
    }

    // --- distribution magnitude cap ---

    function _setMaxDistributionPpm(uint256 ppm) internal {
        vm.startPrank(admin);
        yzilp.grantRole(PRICE_GUARD_MANAGER_ROLE, admin);
        yzilp.setMaxDistributionPpm(ppm);
        vm.stopPrank();
    }

    function test_MaxDistributionPpm_DefaultDisabled() public view {
        assertEq(yzilp.maxDistributionPpm(), type(uint256).max);
    }

    function test_SetMaxDistributionPpm_UpdatesAndEmits() public {
        vm.startPrank(admin);
        yzilp.grantRole(PRICE_GUARD_MANAGER_ROLE, admin);
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedMaxDistributionPpm(type(uint256).max, 50_000);
        yzilp.setMaxDistributionPpm(50_000);
        vm.stopPrank();
        assertEq(yzilp.maxDistributionPpm(), 50_000);
    }

    function test_SetMaxDistributionPpm_Revert_NotPriceGuardManager() public {
        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, poolManager, PRICE_GUARD_MANAGER_ROLE
            )
        );
        yzilp.setMaxDistributionPpm(50_000);
    }

    // A zero cap blocks any nonzero distribution.
    function test_Distribute_Revert_ZeroCapBlocksAll() public {
        _seedPool();
        _setMaxDistributionPpm(0);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionAmountTooHigh.selector, 1, 0));
        yzilp.distribute(1, 1 days);
    }

    // A finite cap admits exactly its ppm of current total assets and nothing more.
    function test_Distribute_CapBoundary_AcceptsExactMax() public {
        _seedPool(); // totalAssets 100e6
        _setMaxDistributionPpm(50_000); // 5%
        vm.prank(poolManager);
        yzilp.distribute(5e6, 1 days);
        assertEq(yzilp.lastDistributedAmount(), 5e6);
    }

    function test_Distribute_Revert_OneAboveCap() public {
        _seedPool();
        _setMaxDistributionPpm(50_000);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionAmountTooHigh.selector, 5e6 + 1, 5e6));
        yzilp.distribute(5e6 + 1, 1 days);
    }

    // The cap is checked before the band, so an over-cap amount fails on the cap even when the
    // projected price sits inside the band.
    function test_BoundedDistribute_CapRevertPrecedesBand() public {
        _seedPool();
        _setMaxDistributionPpm(50_000);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionAmountTooHigh.selector, 10e6, 5e6));
        yzilp.distribute(10e6, 1 days, MIN_PRICE, MAX_PRICE);
    }

    // A within-cap amount still has to satisfy the band.
    function test_BoundedDistribute_WithinCapStillBandChecked() public {
        _seedPool();
        _setMaxDistributionPpm(200_000); // cap 20e6, well above the amount
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(SharePriceTooLow.selector, 1_020_000, 1_050_000));
        yzilp.distribute(2e6, 1 days, 1_050_000, MAX_PRICE);
    }

    // --- unbounded signatures stay callable ---

    function test_UnboundedUpdatePool_StillCallable() public {
        _seedPool();
        vm.startPrank(poolManager);
        yzilp.startPoolUpdate();
        yzilp.updatePool(100e6, 110e6, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
        assertEq(yzilp.poolSize(), 110e6);
    }

    function test_UnboundedDistribute_StillCallable() public {
        _seedPool();
        vm.prank(poolManager);
        yzilp.distribute(10e6, 1 days);
        assertEq(yzilp.lastDistributedAmount(), 10e6);
    }

    // --- distribute / updatePool role separation ---

    function test_Distribute_Revert_PoolManagerWithoutDistributor() public {
        // POOL_MANAGER governs updatePool, not distribution; distributing requires DISTRIBUTOR_ROLE.
        address poolOnly = makeAddr("poolOnly");
        vm.prank(admin);
        yzilp.grantRole(POOL_MANAGER_ROLE, poolOnly);

        _seedPool();
        vm.prank(poolOnly);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolOnly, DISTRIBUTOR_ROLE)
        );
        yzilp.distribute(10e6, 1 days);
    }

    function test_Distribute_DistributorWithoutPoolManager() public {
        // DISTRIBUTOR_ROLE alone authorizes distribution.
        address distributorOnly = makeAddr("distributorOnly");
        vm.prank(admin);
        yzilp.grantRole(DISTRIBUTOR_ROLE, distributorOnly);

        _seedPool();
        vm.prank(distributorOnly);
        yzilp.distribute(10e6, 1 days);
        assertEq(yzilp.lastDistributedAmount(), 10e6);
    }

    // --- minimum distribution period ---

    function test_MinDistributionPeriod_Default() public view {
        assertEq(yzilp.minDistributionPeriod(), 1 days);
    }

    function test_Distribute_Revert_BelowMinDistributionPeriod() public {
        _seedPool();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 1 days - 1, 1 days));
        yzilp.distribute(10e6, 1 days - 1);
    }

    function test_SetMinDistributionPeriod_Updates() public {
        vm.startPrank(admin);
        yzilp.grantRole(PRICE_GUARD_MANAGER_ROLE, admin);
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedMinDistributionPeriod(1 days, 2 days);
        yzilp.setMinDistributionPeriod(2 days);
        vm.stopPrank();
        assertEq(yzilp.minDistributionPeriod(), 2 days);

        // The raised floor is enforced on distribute.
        _seedPool();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 1 days, 2 days));
        yzilp.distribute(10e6, 1 days);
    }

    function test_SetMinDistributionPeriod_Revert_TooLow() public {
        vm.startPrank(admin);
        yzilp.grantRole(PRICE_GUARD_MANAGER_ROLE, admin);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 1 hours - 1, 1 hours));
        yzilp.setMinDistributionPeriod(1 hours - 1);
        vm.stopPrank();
    }

    function test_SetMinDistributionPeriod_Revert_TooHigh() public {
        vm.startPrank(admin);
        yzilp.grantRole(PRICE_GUARD_MANAGER_ROLE, admin);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooHigh.selector, 7 days + 1, 7 days));
        yzilp.setMinDistributionPeriod(7 days + 1);
        vm.stopPrank();
    }

    function test_SetMinDistributionPeriod_Revert_NotPriceGuardManager() public {
        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, poolManager, PRICE_GUARD_MANAGER_ROLE
            )
        );
        yzilp.setMinDistributionPeriod(2 days);
    }
}
