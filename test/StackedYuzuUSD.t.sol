// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {StackedYuzuUSD} from "../src/StackedYuzuUSD.sol";
import {Order} from "../src/interfaces/IStackedYuzuUSD.sol";
import {IStackedYuzuUSDDefinitions} from "../src/interfaces/IStackedYuzuUSDDefinitions.sol";

contract StackedYuzuUSDTest is IStackedYuzuUSDDefinitions, Test {
    StackedYuzuUSD public stackedYzusd;
    ERC20Mock public yzusd;
    address public owner;
    address public user1;
    address public user2;

    uint256 public constant MAX_MINT_PER_BLOCK = 1000e18;
    uint256 public constant MAX_REDEEM_PER_BLOCK = 500e18;
    uint256 public constant REDEEM_WINDOW = 1 days;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock YuzuUSD token
        yzusd = new ERC20Mock();

        // Deploy StackedYuzuUSD
        vm.prank(owner);
        stackedYzusd = new StackedYuzuUSD(
            IERC20(address(yzusd)),
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );

        // Mint some YuzuUSD to users for testing
        yzusd.mint(user1, 10000e18);
        yzusd.mint(user2, 10000e18);
    }

    // Constructor Tests
    function test_Constructor_Success() public {
        assertEq(address(stackedYzusd.asset()), address(yzusd));
        assertEq(stackedYzusd.name(), "Stacked Yuzu USD");
        assertEq(stackedYzusd.symbol(), "st-yzUSD");
        assertEq(stackedYzusd.owner(), owner);
        assertEq(stackedYzusd.maxMintPerBlockInAssets(), MAX_MINT_PER_BLOCK);
        assertEq(
            stackedYzusd.maxRedeemPerBlockInAssets(),
            MAX_REDEEM_PER_BLOCK
        );
        assertEq(stackedYzusd.redeemWindow(), REDEEM_WINDOW);
    }

    // Owner Functions Tests
    function test_SetMaxMintPerBlockInAssets_Success() public {
        uint256 newMax = 2000e18;

        vm.prank(owner);
        stackedYzusd.setMaxMintPerBlockInAssets(newMax);

        assertEq(stackedYzusd.maxMintPerBlockInAssets(), newMax);
    }

    function test_SetMaxMintPerBlockInAssets_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stackedYzusd.setMaxMintPerBlockInAssets(2000e18);
    }

    function test_SetMaxRedeemPerBlockInAssets_Success() public {
        uint256 newMax = 1000e18;

        vm.prank(owner);
        stackedYzusd.setMaxRedeemPerBlockInAssets(newMax);

        assertEq(stackedYzusd.maxRedeemPerBlockInAssets(), newMax);
    }

    function test_SetMaxRedeemPerBlockInAssets_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stackedYzusd.setMaxRedeemPerBlockInAssets(1000e18);
    }

    function test_SetRedeemWindow_Success() public {
        uint256 newWindow = 2 days;

        vm.prank(owner);
        stackedYzusd.setRedeemWindow(newWindow);

        assertEq(stackedYzusd.redeemWindow(), newWindow);
    }

    function test_SetRedeemWindow_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stackedYzusd.setRedeemWindow(2 days);
    }

    // Deposit Tests
    function test_Deposit_Success() public {
        uint256 assets = 100e18;

        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        vm.stopPrank();

        assertEq(stackedYzusd.balanceOf(user1), shares);
        assertEq(stackedYzusd.totalSupply(), shares);
        assertEq(yzusd.balanceOf(address(stackedYzusd)), assets);
    }

    function test_Deposit_RateLimit() public {
        uint256 assets = MAX_MINT_PER_BLOCK + 1;

        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        vm.expectRevert();
        stackedYzusd.deposit(assets, user1);
        vm.stopPrank();
    }

    function test_Deposit_MultipleInSameBlock() public {
        uint256 assets1 = 500e18;
        uint256 assets2 = 400e18;

        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets1);
        stackedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        yzusd.approve(address(stackedYzusd), assets2);
        stackedYzusd.deposit(assets2, user2);
        vm.stopPrank();

        // Should work as total is within limit
        assertEq(
            stackedYzusd.mintedPerBlockInAssets(block.number),
            assets1 + assets2
        );
    }

    function test_Deposit_ExceedRateLimitInSameBlock() public {
        uint256 assets1 = 700e18;
        uint256 assets2 = 400e18; // Total would be 1100e18 > 1000e18

        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets1);
        stackedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        yzusd.approve(address(stackedYzusd), assets2);
        vm.expectRevert();
        stackedYzusd.deposit(assets2, user2);
        vm.stopPrank();
    }

    // Mint Tests
    function test_Mint_Success() public {
        uint256 shares = 100e18;

        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), type(uint256).max);
        uint256 assets = stackedYzusd.mint(shares, user1);
        vm.stopPrank();

        assertEq(stackedYzusd.balanceOf(user1), shares);
        assertEq(stackedYzusd.totalSupply(), shares);
        assertGt(assets, 0);
    }

    // Redeem Initiation Tests
    function test_InitiateRedeem_Success() public {
        // First deposit
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        vm.stopPrank();

        // Then initiate redeem
        vm.startPrank(user1);
        vm.expectEmit();
        emit RedeemInitiated(0, user1, assets, shares);
        (uint256 orderId, ) = stackedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        assertEq(orderId, 0);
        assertEq(stackedYzusd.balanceOf(user1), 0); // Shares burned
        assertEq(stackedYzusd.currentRedeemAssetCommitment(), assets);

        Order memory order = stackedYzusd.getRedeemOrder(orderId);
        assertEq(order.assets, assets);
        assertEq(order.shares, shares);
        assertEq(order.owner, user1);
        assertEq(order.dueTime, block.timestamp + REDEEM_WINDOW);
        assertFalse(order.executed);
    }

    function test_InitiateRedeem_ZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(InvalidAmount.selector);
        stackedYzusd.initiateRedeem(0);
    }

    function test_InitiateRedeem_ExceedsMax() public {
        // Deposit some shares first
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        vm.stopPrank();

        // Try to redeem more than max
        vm.prank(user1);
        vm.expectRevert(MaxRedeemExceeded.selector);
        stackedYzusd.initiateRedeem(shares + 1);
    }

    // Redeem Finalization Tests
    function test_FinalizeRedeem_Success() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        (uint256 orderId, ) = stackedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        uint256 initialBalance = yzusd.balanceOf(user1);

        // Fast forward past redeem window
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);

        vm.expectEmit();
        emit RedeemFinalized(orderId, user1, assets, shares);
        stackedYzusd.finalizeRedeem(orderId);

        assertEq(yzusd.balanceOf(user1), initialBalance + assets);
        assertEq(stackedYzusd.currentRedeemAssetCommitment(), 0);

        Order memory order = stackedYzusd.getRedeemOrder(orderId);
        assertTrue(order.executed);
    }

    function test_FinalizeRedeem_InvalidOrder() public {
        vm.expectRevert(InvalidOrder.selector);
        stackedYzusd.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_NotDue() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        (uint256 orderId, ) = stackedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Try to finalize before due time
        vm.expectRevert(OrderNotDue.selector);
        stackedYzusd.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_AlreadyExecuted() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        uint256 shares = stackedYzusd.deposit(assets, user1);
        (uint256 orderId, ) = stackedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Fast forward and finalize
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);
        stackedYzusd.finalizeRedeem(orderId);

        // Try to finalize again
        vm.expectRevert(OrderAlreadyExecuted.selector);
        stackedYzusd.finalizeRedeem(orderId);
    }

    // ERC4626 Override Tests
    function test_Withdraw_NotSupported() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        stackedYzusd.withdraw(100e18, user1, user1);
    }

    function test_Redeem_NotSupported() public {
        vm.expectRevert(RedeemNotSupported.selector);
        stackedYzusd.redeem(100e18, user1, user1);
    }

    function test_TotalAssets_WithCommitment() public {
        uint256 initialAssets = stackedYzusd.totalAssets();

        // Deposit and initiate redeem
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), depositAmount);
        uint256 shares = stackedYzusd.deposit(depositAmount, user1);
        stackedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Total assets should exclude committed assets
        assertEq(stackedYzusd.totalAssets(), initialAssets);
    }

    function test_MaxDeposit() public {
        assertEq(stackedYzusd.maxDeposit(user1), MAX_MINT_PER_BLOCK);

        // After depositing some amount
        uint256 assets = 300e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets);
        stackedYzusd.deposit(assets, user1);
        vm.stopPrank();

        assertEq(stackedYzusd.maxDeposit(user1), MAX_MINT_PER_BLOCK - assets);
    }

    function test_MaxMint() public {
        uint256 maxDeposit = stackedYzusd.maxDeposit(user1);
        uint256 maxMint = stackedYzusd.maxMint(user1);
        assertEq(maxMint, stackedYzusd.convertToShares(maxDeposit));
    }

    function test_MaxWithdraw() public {
        // Should be 0 since withdraw is not supported (returns 0 from rate limit)
        assertEq(stackedYzusd.maxWithdraw(user1), 0);
    }

    function test_MaxRedeem() public {
        // Should be 0 since redeem is not supported (returns 0 from rate limit)
        assertEq(stackedYzusd.maxRedeem(user1), 0);
    }

    // Integration Tests
    function test_MultipleUsersDepositAndRedeem() public {
        // User1 deposits
        uint256 assets1 = 200e18;
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), assets1);
        uint256 shares1 = stackedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        // User2 deposits
        uint256 assets2 = 300e18;
        vm.startPrank(user2);
        yzusd.approve(address(stackedYzusd), assets2);
        uint256 shares2 = stackedYzusd.deposit(assets2, user2);
        vm.stopPrank();

        // User1 initiates redeem
        vm.prank(user1);
        (uint256 orderId1, ) = stackedYzusd.initiateRedeem(shares1);

        // Fast forward and finalize
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);
        stackedYzusd.finalizeRedeem(orderId1);

        // Verify balances
        assertEq(stackedYzusd.balanceOf(user1), 0);
        assertEq(stackedYzusd.balanceOf(user2), shares2);
        assertEq(stackedYzusd.currentRedeemAssetCommitment(), 0);
    }

    function test_RateLimitResetAcrossBlocks() public {
        // Fill rate limit in first block
        vm.startPrank(user1);
        yzusd.approve(address(stackedYzusd), MAX_MINT_PER_BLOCK);
        stackedYzusd.deposit(MAX_MINT_PER_BLOCK, user1);
        vm.stopPrank();

        // Should fail to deposit more in same block
        vm.startPrank(user2);
        yzusd.approve(address(stackedYzusd), 1e18);
        vm.expectRevert();
        stackedYzusd.deposit(1e18, user2);
        vm.stopPrank();

        // Move to next block
        vm.roll(block.number + 1);

        // Should work in new block
        vm.startPrank(user2);
        yzusd.approve(address(stackedYzusd), 1e18);
        stackedYzusd.deposit(1e18, user2);
        vm.stopPrank();
    }
}
