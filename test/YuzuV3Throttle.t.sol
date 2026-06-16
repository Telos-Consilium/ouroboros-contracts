// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV2} from "../src/YuzuILPV2.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuThrottleDefinitions} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuUSDV3ThrottleTest is Test, IYuzuIssuerDefinitions, IYuzuThrottleDefinitions {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    USDT0Mock asset;
    YuzuUSDV3 yzusd;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address limitManager = makeAddr("limitManager");
    address user = makeAddr("user");
    address exempt = makeAddr("exempt");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);

        address impl = address(new YuzuUSDV3());
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
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
        yzusd = YuzuUSDV3(proxy);
        YuzuUSDV2(proxy).reinitialize();
        yzusd.reinitializeV3();

        vm.startPrank(admin);
        yzusd.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
        vm.prank(exempt);
        asset.approve(proxy, type(uint256).max);
    }

    function test_Throttle_UnlimitedByDefault() public {
        assertEq(yzusd.getMintThrottle().blockLimit, type(uint256).max);
        assertEq(yzusd.getMintThrottle().dailyLimit, type(uint256).max);
        // Throttle is not the binding constraint: a large deposit succeeds
        vm.prank(user);
        yzusd.deposit(1_000_000e6, user);
    }

    function test_MintThrottle_BlockLimit() public {
        vm.prank(limitManager);
        yzusd.setMintThrottle(100e6, type(uint256).max);

        vm.prank(user);
        yzusd.deposit(60e6, user);

        assertEq(yzusd.maxDeposit(user), 40e6); // remaining

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user, 50e6, 40e6));
        yzusd.deposit(50e6, user);

        // Resets next block
        vm.roll(block.number + 1);
        assertEq(yzusd.maxDeposit(user), 100e6);
        vm.prank(user);
        yzusd.deposit(90e6, user);
    }

    function test_MintThrottle_DailyLimit() public {
        vm.prank(limitManager);
        yzusd.setMintThrottle(type(uint256).max, 100e6);

        vm.prank(user);
        yzusd.deposit(70e6, user);
        vm.roll(block.number + 1); // new block, same day
        assertEq(yzusd.maxDeposit(user), 30e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user, 40e6, 30e6));
        yzusd.deposit(40e6, user);
    }

    function test_MintThrottle_ThrottleExempt_Bypasses() public {
        vm.startPrank(admin);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.stopPrank();
        vm.prank(limitManager);
        yzusd.setMintThrottle(100e6, type(uint256).max);

        // Exempt receiver: view unclamped (above the 100e6 block limit), deposit beyond it succeeds
        assertGt(yzusd.maxDeposit(exempt), 100e6);
        vm.prank(exempt);
        yzusd.deposit(500e6, exempt);

        // Public budget untouched by the exempt deposit
        assertEq(yzusd.maxDeposit(user), 100e6);
    }

    function test_RedeemThrottle_BlockLimit() public {
        // Fund the instant liquidity buffer
        vm.prank(admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(1000e6, user);

        vm.prank(limitManager);
        yzusd.setRedeemThrottle(100e6, type(uint256).max);

        vm.prank(user);
        yzusd.withdraw(60e6, user, user);

        assertEq(yzusd.maxWithdraw(user), 40e6); // remaining (no fee set)

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user, 50e6, 40e6));
        yzusd.withdraw(50e6, user, user);
    }

    function test_MintThrottle_ExemptReceiver_NonExemptCaller_Bypasses() public {
        vm.prank(admin);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.prank(limitManager);
        yzusd.setMintThrottle(100e6, type(uint256).max);

        // Exemption follows the receiver: a non-exempt caller minting to the exempt receiver bypasses
        vm.prank(user);
        yzusd.deposit(500e6, exempt);

        // Public budget untouched: nothing consumed against the exempt receiver
        assertEq(yzusd.maxDeposit(user), 100e6);
    }

    function test_RedeemThrottle_ExemptOwner_NonExemptSpender_Bypasses() public {
        vm.startPrank(admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.stopPrank();

        vm.prank(exempt);
        yzusd.deposit(1000e6, exempt);

        vm.prank(limitManager);
        yzusd.setRedeemThrottle(100e6, type(uint256).max);

        vm.prank(exempt);
        yzusd.approve(user, type(uint256).max);

        // Exemption follows the owner: a non-exempt spender redeeming for the exempt owner bypasses
        vm.prank(user);
        yzusd.withdraw(500e6, user, exempt);
    }
}

contract YuzuILPV3ThrottleTest is Test, IYuzuIssuerDefinitions, IYuzuThrottleDefinitions {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    USDT0Mock asset;
    YuzuILPV3 yzilp;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address limitManager = makeAddr("limitManager");
    address user = makeAddr("user");
    address exempt = makeAddr("exempt");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);

        address impl = address(new YuzuILPV3());
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
        yzilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
        vm.prank(exempt);
        asset.approve(proxy, type(uint256).max);
    }

    function test_MintThrottle_BlockLimit() public {
        vm.prank(limitManager);
        yzilp.setMintThrottle(100e6, type(uint256).max);

        vm.prank(user);
        yzilp.deposit(60e6, user);

        assertEq(yzilp.maxDeposit(user), 40e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user, 50e6, 40e6));
        yzilp.deposit(50e6, user);
    }

    function test_MintThrottle_ThrottleExempt_Bypasses() public {
        vm.prank(admin);
        yzilp.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.prank(limitManager);
        yzilp.setMintThrottle(100e6, type(uint256).max);

        vm.prank(exempt);
        yzilp.deposit(500e6, exempt);
        assertEq(yzilp.maxDeposit(user), 100e6);
    }

    function test_InstantRedeem_Disabled() public {
        vm.prank(user);
        yzilp.deposit(100e6, user);

        // yzILP has no instant redeem regardless of the throttle
        assertEq(yzilp.maxWithdraw(user), 0);
        assertEq(yzilp.maxRedeem(user), 0);
    }

    function test_MintThrottle_ExemptReceiver_NonExemptCaller_Bypasses() public {
        vm.prank(admin);
        yzilp.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.prank(limitManager);
        yzilp.setMintThrottle(100e6, type(uint256).max);

        // Exemption follows the receiver: a non-exempt caller minting to the exempt receiver bypasses
        vm.prank(user);
        yzilp.deposit(500e6, exempt);

        assertEq(yzilp.maxDeposit(user), 100e6);
    }
}
