// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuSameBlockGuardDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {REDEEM_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuV3SameBlockGuardTest is YuzuV3TestBase, IYuzuSameBlockGuardDefinitions {
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(other, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);
        yzusd = _deployYuzuUSDV3();

        vm.startPrank(admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzusd));
        _approve(other, address(yzusd));
        _approve(exempt, address(yzusd));
    }

    function test_Withdraw_Revert_SameBlock() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, user));
        yzusd.withdraw(50e6, user, user);
    }

    function test_Redeem_Revert_SameBlock() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, user));
        yzusd.redeem(shares / 2, user, user);
    }

    function test_Withdraw_NextBlock() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.roll(block.number + 1);
        vm.prank(user);
        yzusd.withdraw(50e6, user, user);
    }

    function test_SameBlock_StampsReceiverNotCaller() public {
        // The guard stamps the receiver.
        vm.prank(user);
        yzusd.deposit(100e6, other);

        assertEq(yzusd.lastMintBlock(other), block.number);
        assertEq(yzusd.lastMintBlock(user), 0);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, other));
        yzusd.withdraw(50e6, other, other);
    }

    function test_SameBlock_ExemptReceiver_NotBlocked() public {
        vm.prank(admin);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);

        // Exempt receivers are not stamped.
        vm.prank(exempt);
        yzusd.deposit(100e6, exempt);
        assertEq(yzusd.lastMintBlock(exempt), 0);

        vm.prank(exempt);
        yzusd.withdraw(50e6, exempt, exempt);
    }

    function test_SameBlock_ZeroAmountMint_DoesNotStamp() public {
        // User holds a redeemable position from an earlier block.
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        // Zero-amount mint paths do not stamp the receiver.
        vm.prank(other);
        yzusd.deposit(0, user);
        assertTrue(yzusd.lastMintBlock(user) != block.number);
        vm.prank(other);
        yzusd.mint(0, user);
        assertTrue(yzusd.lastMintBlock(user) != block.number);

        vm.prank(user);
        yzusd.withdraw(50e6, user, user);
    }

    function test_Redeem_Control() public {
        vm.prank(user);
        yzusd.deposit(1_000e6, user);
        vm.roll(block.number + 1);

        uint256 shares = yzusd.balanceOf(user) / 2;
        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);
        assertGt(assets, 0);
    }

    function test_RedeemWithSlippage() public {
        vm.prank(user);
        yzusd.deposit(1_000e6, user);
        vm.roll(block.number + 1);

        uint256 shares = yzusd.balanceOf(user) / 2;
        vm.prank(user);
        uint256 assets = yzusd.redeemWithSlippage(shares, user, user, 0);
        assertGt(assets, 0);
    }

    function test_WithdrawWithSlippage() public {
        vm.prank(user);
        yzusd.deposit(1_000e6, user);
        vm.roll(block.number + 1);

        vm.prank(user);
        uint256 tokens = yzusd.withdrawWithSlippage(100e6, user, user, type(uint256).max);
        assertGt(tokens, 0);
    }
}
