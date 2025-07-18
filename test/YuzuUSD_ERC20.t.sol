// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {YuzuUSD} from "../src/YuzuUSD.sol";

contract YuzuUSDTestERC20 is Test {
    YuzuUSD public yzusd;
    address public owner;
    address public minter;
    address public user1;
    address public user2;

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        yzusd = new YuzuUSD(owner);
    }

    // Constructor Tests
    function test_Constructor() public view {
        assertEq(yzusd.name(), "Yuzu USD");
        assertEq(yzusd.symbol(), "yzUSD");
        assertEq(yzusd.decimals(), 18);
        assertEq(yzusd.owner(), owner);
        assertEq(yzusd.minter(), address(0));
        assertEq(yzusd.totalSupply(), 0);
    }

    // ERC20 Functionality Tests
    function test_Transfer_Success() public {
        // Setup: mint tokens to user1
        vm.prank(owner);
        yzusd.setMinter(minter);
        vm.prank(minter);
        yzusd.mint(user1, 1000e18);

        uint256 transferAmount = 500e18;

        vm.prank(user1);
        vm.expectEmit();
        emit Transfer(user1, user2, transferAmount);

        bool success = yzusd.transfer(user2, transferAmount);

        assertTrue(success);
        assertEq(yzusd.balanceOf(user1), 500e18);
        assertEq(yzusd.balanceOf(user2), 500e18);
    }

    function test_Approve_Success() public {
        uint256 approvalAmount = 1000e18;

        vm.prank(user1);
        bool success = yzusd.approve(user2, approvalAmount);

        assertTrue(success);
        assertEq(yzusd.allowance(user1, user2), approvalAmount);
    }

    function test_TransferFrom_Success() public {
        // Setup: mint tokens and approve
        vm.prank(owner);
        yzusd.setMinter(minter);
        vm.prank(minter);
        yzusd.mint(user1, 1000e18);

        vm.prank(user1);
        yzusd.approve(user2, 500e18);

        vm.prank(user2);
        bool success = yzusd.transferFrom(user1, user2, 300e18);

        assertTrue(success);
        assertEq(yzusd.balanceOf(user1), 700e18);
        assertEq(yzusd.balanceOf(user2), 300e18);
        assertEq(yzusd.allowance(user1, user2), 200e18);
    }

    // Burning Tests
    function test_Burn_Success() public {
        // Setup: mint tokens to user1
        vm.prank(owner);
        yzusd.setMinter(minter);
        vm.prank(minter);
        yzusd.mint(user1, 1000e18);

        uint256 burnAmount = 300e18;

        vm.prank(user1);
        yzusd.burn(burnAmount);

        assertEq(yzusd.balanceOf(user1), 700e18);
        assertEq(yzusd.totalSupply(), 700e18);
    }

    function test_BurnFrom_Success() public {
        // Setup: mint tokens and approve
        vm.prank(owner);
        yzusd.setMinter(minter);
        vm.prank(minter);
        yzusd.mint(user1, 1000e18);

        vm.prank(user1);
        yzusd.approve(user2, 500e18);

        uint256 burnAmount = 300e18;

        vm.prank(user2);
        yzusd.burnFrom(user1, burnAmount);

        assertEq(yzusd.balanceOf(user1), 700e18);
        assertEq(yzusd.totalSupply(), 700e18);
        assertEq(yzusd.allowance(user1, user2), 200e18);
    }

    // Ownership Tests
    function test_TransferOwnership_TwoStep() public {
        vm.prank(owner);
        yzusd.transferOwnership(user1);

        // Ownership should not be transferred yet
        assertEq(yzusd.owner(), owner);
        assertEq(yzusd.pendingOwner(), user1);

        vm.prank(user1);
        yzusd.acceptOwnership();

        assertEq(yzusd.owner(), user1);
        assertEq(yzusd.pendingOwner(), address(0));
    }
}
