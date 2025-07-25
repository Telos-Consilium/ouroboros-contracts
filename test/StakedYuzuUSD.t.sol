// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {Order} from "../src/interfaces/IStakedYuzuUSD.sol";
import {IStakedYuzuUSDDefinitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";

contract StakedYuzuUSDTest is IStakedYuzuUSDDefinitions, Test {
    StakedYuzuUSD public stakedYzusd;
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

        // Deploy StakedYuzuUSD
        vm.prank(owner);
        stakedYzusd = new StakedYuzuUSD(IERC20(address(yzusd)), owner, MAX_MINT_PER_BLOCK, MAX_REDEEM_PER_BLOCK);

        // Mint some YuzuUSD to users for testing
        yzusd.mint(user1, 10000e18);
        yzusd.mint(user2, 10000e18);
    }

    // Constructor Tests
    function test_Constructor_Success() public {
        assertEq(address(stakedYzusd.asset()), address(yzusd));
        assertEq(stakedYzusd.name(), "Staked Yuzu USD");
        assertEq(stakedYzusd.symbol(), "st-yzUSD");
        assertEq(stakedYzusd.owner(), owner);
        assertEq(stakedYzusd.maxDepositPerBlock(), MAX_MINT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdrawPerBlock(), MAX_REDEEM_PER_BLOCK);
        assertEq(stakedYzusd.redeemWindow(), REDEEM_WINDOW);
    }

    // Owner Functions Tests
    function test_SetMaxDepositPerBlock_Success() public {
        uint256 newMax = 2000e18;

        vm.prank(owner);
        stakedYzusd.setMaxDepositPerBlock(newMax);

        assertEq(stakedYzusd.maxDepositPerBlock(), newMax);
    }

    function test_SetMaxDepositPerBlock_RevertOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedYzusd.setMaxDepositPerBlock(2000e18);
    }

    function test_SetMaxWithdrawPerBlock_Success() public {
        uint256 newMax = 1000e18;

        vm.prank(owner);
        stakedYzusd.setMaxWithdrawPerBlock(newMax);

        assertEq(stakedYzusd.maxWithdrawPerBlock(), newMax);
    }

    function test_SetMaxWithdrawPerBlock_RevertOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedYzusd.setMaxWithdrawPerBlock(1000e18);
    }

    function test_SetRedeemWindow_Success() public {
        uint256 newWindow = 2 days;

        vm.prank(owner);
        stakedYzusd.setRedeemWindow(newWindow);

        assertEq(stakedYzusd.redeemWindow(), newWindow);
    }

    function test_SetRedeemWindow_RevertOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        stakedYzusd.setRedeemWindow(2 days);
    }

    // Deposit Tests
    function test_Deposit_Success() public {
        uint256 assets = 100e18;

        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        vm.stopPrank();

        assertEq(stakedYzusd.balanceOf(user1), shares);
        assertEq(stakedYzusd.totalSupply(), shares);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), assets);
    }

    function test_Deposit_RevertRateLimit() public {
        uint256 assets = MAX_MINT_PER_BLOCK + 1;

        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        vm.expectRevert();
        stakedYzusd.deposit(assets, user1);
        vm.stopPrank();
    }

    function test_Deposit_MultipleInSameBlock() public {
        uint256 assets1 = 500e18;
        uint256 assets2 = 400e18;

        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets1);
        stakedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        yzusd.approve(address(stakedYzusd), assets2);
        stakedYzusd.deposit(assets2, user2);
        vm.stopPrank();

        // Should work as total is within limit
        assertEq(stakedYzusd.depositedPerBlock(block.number), assets1 + assets2);
    }

    function test_Deposit_RevertExceedRateLimitInSameBlock() public {
        uint256 assets1 = 700e18;
        uint256 assets2 = 400e18; // Total would be 1100e18 > 1000e18

        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets1);
        stakedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        yzusd.approve(address(stakedYzusd), assets2);
        vm.expectRevert();
        stakedYzusd.deposit(assets2, user2);
        vm.stopPrank();
    }

    // Mint Tests
    function test_Mint_Success() public {
        uint256 shares = 100e18;

        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), type(uint256).max);
        uint256 assets = stakedYzusd.mint(shares, user1);
        vm.stopPrank();

        assertEq(stakedYzusd.balanceOf(user1), shares);
        assertEq(stakedYzusd.totalSupply(), shares);
        assertGt(assets, 0);
    }

    // Redeem Initiation Tests
    function test_InitiateRedeem_Success() public {
        // First deposit
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        vm.stopPrank();

        // Then initiate redeem
        vm.startPrank(user1);
        vm.expectEmit();
        emit RedeemInitiated(0, user1, assets, shares);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        assertEq(orderId, 0);
        assertEq(stakedYzusd.balanceOf(user1), 0); // Shares burned
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), assets);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertEq(order.assets, assets);
        assertEq(order.shares, shares);
        assertEq(order.owner, user1);
        assertEq(order.dueTime, block.timestamp + REDEEM_WINDOW);
        assertFalse(order.executed);
    }

    function test_InitiateRedeem_RevertZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(InvalidAmount.selector);
        stakedYzusd.initiateRedeem(0);
    }

    function test_InitiateRedeem_RevertExceedsMax() public {
        // Deposit some shares first
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        vm.stopPrank();

        // Try to redeem more than max
        vm.prank(user1);
        vm.expectRevert(MaxRedeemExceeded.selector);
        stakedYzusd.initiateRedeem(shares + 1);
    }

    // Redeem Finalization Tests
    function test_FinalizeRedeem_Success() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        uint256 initialBalance = yzusd.balanceOf(user1);

        // Fast forward past redeem window
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);

        vm.expectEmit();
        emit RedeemFinalized(orderId, user1, assets, shares);
        stakedYzusd.finalizeRedeem(orderId);

        assertEq(yzusd.balanceOf(user1), initialBalance + assets);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertTrue(order.executed);
    }

    function test_FinalizeRedeem_RevertInvalidOrder() public {
        vm.expectRevert(InvalidOrder.selector);
        stakedYzusd.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_RevertNotDue() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Try to finalize before due time
        vm.expectRevert(OrderNotDue.selector);
        stakedYzusd.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_RevertAlreadyExecuted() public {
        // Setup: deposit and initiate redeem
        uint256 assets = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        uint256 shares = stakedYzusd.deposit(assets, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Fast forward and finalize
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);
        stakedYzusd.finalizeRedeem(orderId);

        // Try to finalize again
        vm.expectRevert(OrderAlreadyExecuted.selector);
        stakedYzusd.finalizeRedeem(orderId);
    }

    // ERC4626 Override Tests
    function test_Withdraw_RevertNotSupported() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        stakedYzusd.withdraw(100e18, user1, user1);
    }

    function test_Redeem_RevertNotSupported() public {
        vm.expectRevert(RedeemNotSupported.selector);
        stakedYzusd.redeem(100e18, user1, user1);
    }

    function test_TotalAssets_WithCommitment() public {
        uint256 initialAssets = stakedYzusd.totalAssets();

        // Deposit and initiate redeem
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), depositAmount);
        uint256 shares = stakedYzusd.deposit(depositAmount, user1);
        stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Total assets should exclude committed assets
        assertEq(stakedYzusd.totalAssets(), initialAssets);
    }

    function test_MaxDeposit() public {
        assertEq(stakedYzusd.maxDeposit(user1), MAX_MINT_PER_BLOCK);

        // After depositing some amount
        uint256 assets = 300e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets);
        stakedYzusd.deposit(assets, user1);
        vm.stopPrank();

        assertEq(stakedYzusd.maxDeposit(user1), MAX_MINT_PER_BLOCK - assets);
    }

    function test_MaxMint() public {
        uint256 maxDeposit = stakedYzusd.maxDeposit(user1);
        uint256 maxMint = stakedYzusd.maxMint(user1);
        assertEq(maxMint, stakedYzusd.convertToShares(maxDeposit));
    }

    function test_MaxWithdraw() public {
        // Should be 0 since withdraw is not supported (returns 0 from rate limit)
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
    }

    function test_MaxRedeem() public {
        // Should be 0 since redeem is not supported (returns 0 from rate limit)
        assertEq(stakedYzusd.maxRedeem(user1), 0);
    }

    // Integration Tests
    function test_MultipleUsersDepositAndRedeem() public {
        // User1 deposits
        uint256 assets1 = 200e18;
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), assets1);
        uint256 shares1 = stakedYzusd.deposit(assets1, user1);
        vm.stopPrank();

        // User2 deposits
        uint256 assets2 = 300e18;
        vm.startPrank(user2);
        yzusd.approve(address(stakedYzusd), assets2);
        uint256 shares2 = stakedYzusd.deposit(assets2, user2);
        vm.stopPrank();

        // User1 initiates redeem
        vm.prank(user1);
        (uint256 orderId1,) = stakedYzusd.initiateRedeem(shares1);

        // Fast forward and finalize
        vm.warp(block.timestamp + REDEEM_WINDOW + 1);
        stakedYzusd.finalizeRedeem(orderId1);

        // Verify balances
        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), shares2);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
    }

    function test_RateLimitResetAcrossBlocks() public {
        // Fill rate limit in first block
        vm.startPrank(user1);
        yzusd.approve(address(stakedYzusd), MAX_MINT_PER_BLOCK);
        stakedYzusd.deposit(MAX_MINT_PER_BLOCK, user1);
        vm.stopPrank();

        // Should fail to deposit more in same block
        vm.startPrank(user2);
        yzusd.approve(address(stakedYzusd), 1e18);
        vm.expectRevert();
        stakedYzusd.deposit(1e18, user2);
        vm.stopPrank();

        // Move to next block
        vm.roll(block.number + 1);

        // Should work in new block
        vm.startPrank(user2);
        yzusd.approve(address(stakedYzusd), 1e18);
        stakedYzusd.deposit(1e18, user2);
        vm.stopPrank();
    }

    function test_DonationAttack_NoProfit() public {
        address attacker = user1;
        address victim = user2;

        uint256 attackerDeposit = 1e18;
        uint256 attackerDonation = 100_000_000e18;
        uint256 victimDeposit = 1e18;

        vm.startPrank(owner);
        stakedYzusd.setMaxDepositPerBlock(type(uint256).max);
        stakedYzusd.setMaxWithdrawPerBlock(type(uint256).max);
        vm.stopPrank();

        // Attacker deposits
        vm.startPrank(attacker);
        yzusd.approve(address(stakedYzusd), attackerDeposit);
        uint256 attackerShares = stakedYzusd.deposit(attackerDeposit, attacker);
        vm.stopPrank();

        // Attacker donates underlying directly to the vault
        yzusd.mint(address(stakedYzusd), attackerDonation);

        // Victim deposits
        vm.startPrank(victim);
        yzusd.approve(address(stakedYzusd), victimDeposit);
        stakedYzusd.deposit(victimDeposit, victim);
        vm.stopPrank();

        // Attacker tries to profit by redeeming
        vm.startPrank(attacker);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(attackerShares);
        vm.stopPrank();

        Order memory order = stakedYzusd.getRedeemOrder(orderId);

        assertLe(order.assets, attackerDeposit + attackerDonation);
        assertEq(order.shares, attackerShares);
    }
}
