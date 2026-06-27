// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV2} from "../src/YuzuILPV2.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {YuzuILPV3Facet} from "../src/YuzuILPV3Facet.sol";
import {IYuzuILPDefinitions, IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuILPV3PriceGuardTest is Test, IYuzuILPDefinitions, IYuzuILPV3Definitions {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    // Share price is the USDT0 value of one whole share; the seeded pool sits at par (1 USDT0)
    uint256 internal constant MIN_PRICE = 950_000;
    uint256 internal constant MAX_PRICE = 1_200_000;

    USDT0Mock asset;
    YuzuILPV3 yzilp;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address poolManager = makeAddr("poolManager");
    address user = makeAddr("user");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);

        address impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(asset),
            "Token",
            "TKN",
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        address proxy = address(new ERC1967Proxy(impl, initData));
        yzilp = YuzuILPV3(proxy);
        YuzuILPV2(proxy).reinitialize();
        yzilp.reinitializeV3();

        vm.startPrank(admin);
        yzilp.grantRole(POOL_MANAGER_ROLE, poolManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
    }

    // --- helpers ---

    // Seeds supply 100e18 and poolSize 100e6, so price is 1e6 (par) and newPoolSize P gives price P/100
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

    function test_UpdatePool_Revert_FormerlyValidYieldNowRejected() public {
        // 500_000 ppm (50%/day) passed the old 1e6 cap but exceeds the V3 ceiling
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
        // Fat-finger: 1100e6 implies a price of 11e6, far above the band
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
        // Fat-finger: 1000e6 distributed implies an end price of 11e6
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
}
