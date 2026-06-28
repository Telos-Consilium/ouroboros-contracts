// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
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

    function test_YuzUSD_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.deposit(5e6, user);

        vm.prank(user);
        yzusd.deposit(10e6, user); // at the floor, succeeds
    }

    function test_YuzUSD_Mint_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        uint256 shares = yzusd.previewDeposit(5e6); // worth 5e6 assets
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.mint(shares, user);
    }

    function test_YuzUSD_Withdraw_Revert_UnderMinWithdraw() public {
        // Fund the instant liquidity buffer so maxWithdraw is non-zero
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1); // same-block guard: redeem in a later block than the mint

        vm.prank(limitManager);
        yzusd.setMinWithdraw(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 5e6, 10e6));
        yzusd.withdraw(5e6, user, user);

        vm.prank(user);
        yzusd.withdraw(10e6, user, user); // at the floor, succeeds
    }

    // yzILP mint path

    function test_YuzILP_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzilp.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzilp.deposit(5e6, user);

        vm.prank(user);
        yzilp.deposit(10e6, user); // at the floor, succeeds
    }

    // Min floor reflected in the ERC-4626 max views (clamped to 0 when remaining capacity is below the floor)

    function test_YuzUSD_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzusd.setMinDeposit(10e6);
        yzusd.setMintThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzusd.maxDeposit(user), 0);
        assertEq(yzusd.maxMint(user), 0);
    }

    function test_YuzUSD_MaxWithdraw_ClampedToZero_BelowMinFloor() public {
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.startPrank(limitManager);
        yzusd.setMinWithdraw(10e6);
        yzusd.setRedeemThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzusd.maxWithdraw(user), 0);
        assertEq(yzusd.maxRedeem(user), 0);
    }

    function test_YuzILP_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzilp.setMinDeposit(10e6);
        yzilp.setMintThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);
    }
}
