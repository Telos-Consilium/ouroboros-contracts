// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {REDEEM_MANAGER_ROLE, SAME_BLOCK_EXEMPT_ROLE, THROTTLE_EXEMPT_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuV3SameBlockGuardTest is YuzuV3TestBase, IYuzuIssuerDefinitions {
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

    function test_FreshDeposit_RestrictsShares() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        assertEq(yzusd.currentBlockRestrictedBalance(user), shares);
        assertEq(yzusd.maxRedeem(user), 0);
        assertEq(yzusd.maxWithdraw(user), 0);
    }

    function test_Redeem_Revert_SameBlock() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user, shares / 2, 0));
        yzusd.redeem(shares / 2, user, user);
    }

    function test_Withdraw_Revert_SameBlock() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user, 50e6, 0));
        yzusd.withdraw(50e6, user, user);
    }

    function test_TransferBypass_Closed() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        vm.prank(user);
        yzusd.transfer(other, shares);

        assertEq(yzusd.currentBlockRestrictedBalance(other), shares);
        assertEq(yzusd.maxRedeem(other), 0);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, other, shares, 0));
        yzusd.redeem(shares, other, other);
    }

    function test_DustReceipt_DoesNotBlockMatureShares() public {
        vm.prank(other);
        uint256 mature = yzusd.deposit(100e6, other);
        vm.prank(user);
        uint256 fresh = yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        // Mature `other` receives a one-share transfer in the current block.
        vm.prank(user);
        yzusd.transfer(other, 1);

        assertEq(yzusd.currentBlockRestrictedBalance(other), 1);
        assertEq(yzusd.maxRedeem(other), mature);

        vm.prank(other);
        yzusd.redeem(mature, other, other);

        // The dust remains restricted for the rest of the block.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, other, 1, 0));
        yzusd.redeem(1, other, other);
        fresh; // silence unused
    }

    function test_MultiHopTransfer_PropagatesRestriction() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        vm.prank(user);
        yzusd.transfer(other, shares);
        vm.prank(other);
        yzusd.transfer(exempt, shares);

        assertEq(yzusd.currentBlockRestrictedBalance(exempt), shares);
    }

    function test_PartialTransfer_ConsumesMatureFirst() public {
        // user holds shares from a mature 100e6 deposit, then deposits another 100e6 this block.
        vm.prank(user);
        uint256 matureShares = yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);
        vm.prank(user);
        uint256 freshShares = yzusd.deposit(100e6, user);
        assertEq(yzusd.currentBlockRestrictedBalance(user), freshShares);

        // Transferring the mature capacity leaves the current-block restriction with user.
        vm.prank(user);
        yzusd.transfer(other, matureShares);

        assertEq(yzusd.currentBlockRestrictedBalance(user), freshShares);
        assertEq(yzusd.currentBlockRestrictedBalance(other), matureShares);
    }

    function test_NextBlock_Matures() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);
        vm.prank(user);
        yzusd.transfer(other, shares);

        vm.roll(block.number + 1);
        assertEq(yzusd.currentBlockRestrictedBalance(other), 0);
        vm.prank(other);
        yzusd.redeem(shares, other, other);
    }

    function test_SelfTransfer_DoesNotRestrictMature() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        vm.prank(user);
        yzusd.transfer(user, shares);
        assertEq(yzusd.currentBlockRestrictedBalance(user), 0);
        assertEq(yzusd.maxRedeem(user), shares);
    }

    function test_ExemptOwner_BooksButBypasses() public {
        vm.prank(admin);
        yzusd.grantRole(SAME_BLOCK_EXEMPT_ROLE, exempt);

        vm.prank(exempt);
        uint256 shares = yzusd.deposit(100e6, exempt);

        // Bookkeeping still records the fresh shares.
        assertEq(yzusd.currentBlockRestrictedBalance(exempt), shares);
        // Enforcement is bypassed for the exempt owner.
        assertEq(yzusd.maxRedeem(exempt), shares);
        vm.prank(exempt);
        yzusd.redeem(shares, exempt, exempt);
    }

    // Throttle exemption alone does not bypass the same-block guard; the two are separate roles.
    function test_ThrottleExemptOnly_StillRestricted() public {
        vm.prank(admin);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);

        vm.prank(exempt);
        uint256 shares = yzusd.deposit(100e6, exempt);

        assertEq(yzusd.currentBlockRestrictedBalance(exempt), shares);
        assertEq(yzusd.maxRedeem(exempt), 0);
        vm.prank(exempt);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, exempt, shares, 0));
        yzusd.redeem(shares, exempt, exempt);
    }

    function test_OrderPath_NotRestricted() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        // The redeem-order path remains usable with same-block shares.
        vm.prank(user);
        yzusd.createRedeemOrder(shares, user, user);
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
