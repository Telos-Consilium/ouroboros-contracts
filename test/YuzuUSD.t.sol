// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {IYuzuUSDDefinitions} from "../src/interfaces/IYuzuUSDDefinitions.sol";

contract YuzuUSDTest is IYuzuUSDDefinitions, Test {
    YuzuUSD public yzusd;
    address public owner;
    address public minter;
    address public user1;
    address public user2;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        owner = makeAddr("owner");
        minter = makeAddr("minter");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        vm.prank(owner);
        yzusd = new YuzuUSD("Yuzu USD", "yzUSD", owner);
    }

    // Admin Functions
    function test_SetMinter() public {
        vm.prank(owner);
        vm.expectEmit();
        emit MinterUpdated(address(0), minter);

        yzusd.setMinter(minter);

        assertEq(yzusd.minter(), minter);
    }

    function test_SetMinter_RevertOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        yzusd.setMinter(minter);
    }

    function test_SetMinter_UpdateExistingMinter() public {
        // Set initial minter
        vm.prank(owner);
        yzusd.setMinter(minter);

        address newMinter = makeAddr("newMinter");

        vm.prank(owner);
        vm.expectEmit();
        emit MinterUpdated(minter, newMinter);

        yzusd.setMinter(newMinter);

        assertEq(yzusd.minter(), newMinter);
    }

    function test_SetMinter_ZeroAddress() public {
        vm.prank(owner);
        vm.expectEmit();
        emit MinterUpdated(address(0), address(0));

        yzusd.setMinter(address(0));

        assertEq(yzusd.minter(), address(0));
    }

    // Mint
    function test_Mint() public {
        vm.prank(owner);
        yzusd.setMinter(minter);

        uint256 amount = 1000e18;

        vm.prank(minter);
        vm.expectEmit();
        emit Transfer(address(0), user1, amount);

        yzusd.mint(user1, amount);

        assertEq(yzusd.balanceOf(user1), amount);
        assertEq(yzusd.totalSupply(), amount);
    }

    function test_Mint_RevertOnlyMinter() public {
        vm.prank(owner);
        yzusd.setMinter(minter);

        vm.prank(user1);
        vm.expectRevert(OnlyMinter.selector);
        yzusd.mint(user1, 1000e18);
    }

    function test_Mint_RevertNoMinterSet() public {
        vm.prank(owner);
        vm.expectRevert(OnlyMinter.selector);
        yzusd.mint(user1, 1000e18);
    }

    function test_Mint_ZeroAmount() public {
        vm.prank(owner);
        yzusd.setMinter(minter);

        vm.prank(minter);
        yzusd.mint(user1, 0);

        assertEq(yzusd.balanceOf(user1), 0);
        assertEq(yzusd.totalSupply(), 0);
    }

    // Edge Cases and Fuzz
    function testFuzz_Mint_RandomAmounts(uint256 amount) public {
        vm.assume(amount <= type(uint256).max / 2); // Avoid overflow

        vm.prank(owner);
        yzusd.setMinter(minter);

        vm.prank(minter);
        yzusd.mint(user1, amount);

        assertEq(yzusd.balanceOf(user1), amount);
        assertEq(yzusd.totalSupply(), amount);
    }

    function testFuzz_SetMinter_RandomAddresses(address randomMinter) public {
        vm.prank(owner);
        yzusd.setMinter(randomMinter);

        assertEq(yzusd.minter(), randomMinter);
    }

    function test_MultipleMints() public {
        vm.prank(owner);
        yzusd.setMinter(minter);

        vm.startPrank(minter);
        yzusd.mint(user1, 500e18);
        yzusd.mint(user2, 300e18);
        yzusd.mint(user1, 200e18);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1), 700e18);
        assertEq(yzusd.balanceOf(user2), 300e18);
        assertEq(yzusd.totalSupply(), 1000e18);
    }

    // Integration
    function test_FullWorkflow() public {
        // 1. Set minter
        vm.prank(owner);
        yzusd.setMinter(minter);

        // 2. Mint tokens
        vm.prank(minter);
        yzusd.mint(user1, 1000e18);

        // 3. Transfer tokens
        vm.prank(user1);
        yzusd.transfer(user2, 300e18);

        // 4. Approve and transferFrom
        vm.prank(user1);
        yzusd.approve(user2, 200e18);
        vm.prank(user2);
        yzusd.transferFrom(user1, user2, 150e18);

        // 5. Burn tokens
        vm.prank(user1);
        yzusd.burn(100e18);

        // Verify final state
        assertEq(yzusd.balanceOf(user1), 450e18); // 1000 - 300 - 150 - 100
        assertEq(yzusd.balanceOf(user2), 450e18); // 300 + 150
        assertEq(yzusd.totalSupply(), 900e18); // 1000 - 100 (burned)
        assertEq(yzusd.allowance(user1, user2), 50e18); // 200 - 150
    }
}
