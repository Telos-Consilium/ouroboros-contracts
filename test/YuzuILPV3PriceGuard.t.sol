// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IYuzuILPDefinitions,
    IYuzuILPV2Definitions,
    IYuzuILPV3Definitions
} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {DISTRIBUTOR_ROLE, POOL_MANAGER_ROLE, PRICE_GUARD_MANAGER_ROLE} from "./helpers/TestRoles.sol";
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
