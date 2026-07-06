// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuThrottleDefinitions} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {LIMIT_MANAGER_ROLE, REDEEM_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase, YuzuV3USDT0Mock} from "./helpers/YuzuV3TestBase.sol";

contract ReentrantAsset is YuzuV3USDT0Mock {
    YuzuUSDV3 public vault;
    address public receiver;
    uint256 public reenterAmount;
    bool private entered;

    function arm(YuzuUSDV3 _vault, address _receiver, uint256 _amount) external {
        vault = _vault;
        receiver = _receiver;
        reenterAmount = _amount;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!entered && address(vault) != address(0)) {
            entered = true;
            vault.deposit(reenterAmount, receiver);
        }
        return super.transferFrom(from, to, value);
    }
}

contract YuzuUSDV3ThrottleTest is YuzuV3TestBase, IYuzuIssuerDefinitions, IYuzuThrottleDefinitions {
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);
        yzusd = _deployYuzuUSDV3();

        vm.startPrank(admin);
        yzusd.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzusd));
        _approve(exempt, address(yzusd));
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
        // Fund the instant liquidity buffer.
        vm.prank(admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(1000e6, user);
        vm.roll(block.number + 1);

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

    function test_MintThrottle_NotBypassableViaReentrancy() public {
        ReentrantAsset reentrantAsset = new ReentrantAsset();
        asset = reentrantAsset;
        asset.mint(user, 10_000_000e6);
        asset.mint(address(asset), 10_000_000e6);
        yzusd = _deployYuzuUSDV3(address(asset));

        vm.startPrank(admin);
        yzusd.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzusd.setMintThrottle(100e6, type(uint256).max);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzusd));
        _approve(address(asset), address(yzusd));

        reentrantAsset.arm(yzusd, user, 60e6);
        vm.prank(user);
        vm.expectRevert();
        yzusd.deposit(60e6, user);
    }
}

contract YuzuILPV3ThrottleTest is YuzuV3TestBase, IYuzuIssuerDefinitions, IYuzuThrottleDefinitions {
    uint256 internal constant YUZU_THROTTLE_STORAGE_LOCATION =
        0x0b7c362ff29744eee18a40453a4b4ef5d7bd130da15027ce5dd041799a288e00;

    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);
        yzilp = _deployYuzuILPV3();

        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
        _approve(exempt, address(yzilp));
    }

    function test_Throttle_UnlimitedByDefault() public view {
        assertEq(yzilp.getMintThrottle().blockLimit, type(uint256).max);
        assertEq(yzilp.getMintThrottle().dailyLimit, type(uint256).max);
        assertEq(uint256(vm.load(address(yzilp), bytes32(YUZU_THROTTLE_STORAGE_LOCATION + 6))), type(uint256).max);
        assertEq(uint256(vm.load(address(yzilp), bytes32(YUZU_THROTTLE_STORAGE_LOCATION + 7))), type(uint256).max);
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
