// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuOrderBookDefinitions} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {LIMIT_MANAGER_ROLE, REDEEM_MANAGER_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuV3MinAmountsTest is YuzuV3TestBase, IYuzuMinAmountsDefinitions {
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);

        yzusd = _deployYuzuUSDV3(address(asset), "Token", "TKN", false);
        yzilp = _deployYuzuILPV3(address(asset), "Token", "TKN", false);

        vm.startPrank(user);
        asset.approve(address(yzusd), type(uint256).max);
        asset.approve(address(yzilp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(admin);
        yzusd.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzilp.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();
    }

    // Setters

    function test_SetMinDeposit_Revert_NotLimitManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, LIMIT_MANAGER_ROLE)
        );
        yzusd.setMinDeposit(10e6);
    }

    function test_SetMinDeposit_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UpdatedMinDeposit(0, 10e6);
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);
        assertEq(yzusd.minDeposit(), 10e6);
    }

    // yzUSD instant paths

    function test_YuzuUSD_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.deposit(5e6, user);

        vm.prank(user);
        yzusd.deposit(10e6, user);
    }

    function test_YuzuUSD_Mint_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        uint256 shares = yzusd.previewDeposit(5e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.mint(shares, user);
    }

    function test_YuzuUSD_Withdraw_Revert_UnderMinWithdraw() public {
        // Fund the instant liquidity buffer.
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        vm.prank(limitManager);
        yzusd.setMinWithdraw(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 5e6, 10e6));
        yzusd.withdraw(5e6, user, user);

        vm.prank(user);
        yzusd.withdraw(10e6, user, user);
    }

    function test_YuzuUSD_CreateRedeemOrder_Revert_UnderMinRedeemOrder() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.prank(limitManager);
        yzusd.setMinRedeemOrder(10e18);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IYuzuOrderBookDefinitions.UnderMinRedeemOrder.selector, 5e18, 10e18));
        yzusd.createRedeemOrder(5e18, user, user);

        vm.prank(user);
        yzusd.createRedeemOrder(10e18, user, user);
    }

    function test_YuzuUSD_CreateRedeemOrder_Revert_ZeroShares() public {
        vm.prank(user);
        vm.expectRevert(IYuzuOrderBookDefinitions.InvalidZeroShares.selector);
        yzusd.createRedeemOrder(0, user, user);
    }

    function test_YuzuILP_CreateRedeemOrder_Revert_ZeroShares() public {
        vm.prank(user);
        vm.expectRevert(IYuzuOrderBookDefinitions.InvalidZeroShares.selector);
        yzilp.createRedeemOrder(0, user, user);
    }

    // yzILP mint path

    function test_YuzuILP_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzilp.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzilp.deposit(5e6, user);

        vm.prank(user);
        yzilp.deposit(10e6, user);
    }

    // ERC-4626 max views clamp to 0 below the configured floor.

    function test_YuzuUSD_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzusd.setMinDeposit(10e6);
        yzusd.setMintThrottle(5e6, type(uint256).max);
        vm.stopPrank();

        assertEq(yzusd.maxDeposit(user), 0);
        assertEq(yzusd.maxMint(user), 0);
    }

    function test_YuzuUSD_MaxWithdraw_ClampedToZero_BelowMinFloor() public {
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.startPrank(limitManager);
        yzusd.setMinWithdraw(10e6);
        yzusd.setRedeemThrottle(5e6, type(uint256).max);
        vm.stopPrank();

        assertEq(yzusd.maxWithdraw(user), 0);
        assertEq(yzusd.maxRedeem(user), 0);
    }

    function test_YuzuILP_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzilp.setMinDeposit(10e6);
        yzilp.setMintThrottle(5e6, type(uint256).max);
        vm.stopPrank();

        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);
    }
}
