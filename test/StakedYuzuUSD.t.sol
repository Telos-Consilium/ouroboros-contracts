// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {Order} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IStakedYuzuUSDDefinitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";

contract StakedYuzuUSDTest is IStakedYuzuUSDDefinitions, Test {
    // ERC-4626 events for testing
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    
    StakedYuzuUSD public stakedYzusd;
    ERC20Mock public yzusd;
    address public owner;
    address public user1;
    address public user2;

    uint256 public constant MAX_DEPOSIT_PER_BLOCK = 1_000e18;
    uint256 public constant MAX_WITHDRAW_PER_BLOCK = 500e18;
    uint256 public constant REDEEM_DELAY = 1 days;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock YuzuUSD token
        yzusd = new ERC20Mock();

        // Deploy StakedYuzuUSD implementation
        StakedYuzuUSD implementation = new StakedYuzuUSD();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            owner,
            MAX_DEPOSIT_PER_BLOCK,
            MAX_WITHDRAW_PER_BLOCK
        );

        // Deploy proxy and initialize
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        stakedYzusd = StakedYuzuUSD(address(proxy));

        // Mint some YuzuUSD to users for testing
        yzusd.mint(user1, 10_000e18);
        yzusd.mint(user2, 10_000e18);

        vm.prank(user1);
        yzusd.approve(address(stakedYzusd), type(uint256).max);

        vm.prank(user2);
        yzusd.approve(address(stakedYzusd), type(uint256).max);
    }

    // Initialization
    function test_Initialize() public {
        assertEq(address(stakedYzusd.asset()), address(yzusd));
        assertEq(stakedYzusd.name(), "Staked Yuzu USD");
        assertEq(stakedYzusd.symbol(), "st-yzUSD");
        assertEq(stakedYzusd.owner(), owner);
        assertEq(stakedYzusd.maxDepositPerBlock(), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdrawPerBlock(), MAX_WITHDRAW_PER_BLOCK);
        assertEq(stakedYzusd.redeemDelay(), REDEEM_DELAY);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
    }

    // Admin Functions
    function test_SetMaxDepositPerBlock() public {
        uint256 newMax = 2_000e18;

        vm.expectEmit();
        emit MaxDepositPerBlockUpdated(MAX_DEPOSIT_PER_BLOCK, newMax);
        vm.prank(owner);
        stakedYzusd.setMaxDepositPerBlock(newMax);

        assertEq(stakedYzusd.maxDepositPerBlock(), newMax);
    }

    function test_SetMaxDepositPerBlock_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setMaxDepositPerBlock(2_000e18);
    }

    function test_SetMaxWithdrawPerBlock() public {
        uint256 newMax = 1_000e18;

        vm.expectEmit();
        emit MaxWithdrawPerBlockUpdated(MAX_WITHDRAW_PER_BLOCK, newMax);
        vm.prank(owner);
        stakedYzusd.setMaxWithdrawPerBlock(newMax);

        assertEq(stakedYzusd.maxWithdrawPerBlock(), newMax);
    }

    function test_SetMaxWithdrawPerBlock_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setMaxWithdrawPerBlock(1_000e18);
    }

    function test_SetRedeemDelay() public {
        uint256 newDelay = 2 days;

        vm.expectEmit();
        emit RedeemDelayUpdated(REDEEM_DELAY, newDelay);
        vm.prank(owner);
        stakedYzusd.setRedeemDelay(newDelay);

        assertEq(stakedYzusd.redeemDelay(), newDelay);
    }

    function test_SetRedeemDelay_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setRedeemDelay(2 days);
    }

    function test_RescueTokens() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 100e18;
        otherToken.mint(address(stakedYzusd), amount);
        uint256 balanceBefore = otherToken.balanceOf(user1);
        vm.prank(owner);
        stakedYzusd.rescueTokens(address(otherToken), user1, amount);
        assertEq(otherToken.balanceOf(user1), balanceBefore + amount);
    }

    function test_RescueTokens_RevertOnlyOwner() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 100e18;
        otherToken.mint(address(stakedYzusd), amount);
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.rescueTokens(address(otherToken), user1, amount);
    }

    function test_RescueTokens_RevertUnderlyingToken() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(yzusd)));
        vm.prank(owner);
        stakedYzusd.rescueTokens(address(yzusd), user1, 100e18);
    }

    // Deposit
    function test_Deposit() public {
        uint256 depositSize = 200e18;
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, depositSize, depositSize);
        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);

        assertEq(stakedYzusd.balanceOf(user1), shares);
        assertEq(stakedYzusd.totalSupply(), shares);
        assertEq(stakedYzusd.totalAssets(), shares);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositSize);
        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore - depositSize);
        assertEq(stakedYzusd.depositedPerBlock(block.number), depositSize);
    }

    function test_Deposit_RevertLimitExceeded() public {
        uint256 depositSize = MAX_DEPOSIT_PER_BLOCK + 1;

        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);
    }

    function test_Deposit_MultipleInSameBlock_RevertLimitExceeded() public {
        uint256 depositSize1 = MAX_DEPOSIT_PER_BLOCK;
        uint256 depositSize2 = 200e18;

        vm.prank(user1);
        stakedYzusd.deposit(depositSize1, user1);

        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.deposit(depositSize2, user2);
    }

    // Mint
    function test_Mint() public {
        uint256 mintSize = 200e18;
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, mintSize, mintSize);
        vm.prank(user1);
        uint256 assets = stakedYzusd.mint(mintSize, user1);

        assertEq(assets, mintSize);
        assertEq(stakedYzusd.balanceOf(user1), assets);
        assertEq(stakedYzusd.totalSupply(), assets);
        assertEq(stakedYzusd.totalAssets(), assets);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), assets);
        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore - assets);
        assertEq(stakedYzusd.depositedPerBlock(block.number), assets);
    }

    function test_Mint_RevertLimitExceeded() public {
        uint256 mintSize = MAX_DEPOSIT_PER_BLOCK + 1;

        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.mint(mintSize, user1);
    }

    function test_Mint_MultipleInSameBlock_RevertLimitExceeded() public {
        uint256 mintSize1 = MAX_DEPOSIT_PER_BLOCK;
        uint256 mintSize2 = 200e18;

        vm.prank(user1);
        stakedYzusd.mint(mintSize1, user1);

        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.mint(mintSize2, user2);
    }

    // Redeem Initiation
    function test_InitiateRedeem() public {
        // Deposit
        uint256 depositSize = 200e18;
        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);

        // Initiate redeem
        vm.expectEmit();
        emit RedeemInitiated(0, user1, depositSize, shares);
        vm.prank(user1);
        (uint256 orderId, uint256 _assets) = stakedYzusd.initiateRedeem(shares);

        assertEq(orderId, 0);
        assertEq(_assets, depositSize);
        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositSize);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertEq(order.assets, depositSize);
        assertEq(order.shares, shares);
        assertEq(order.owner, user1);
        assertEq(order.dueTime, block.timestamp + REDEEM_DELAY);
        assertFalse(order.executed);
    }

    function test_InitiateRedeem_RevertZeroShares() public {
        vm.expectRevert(InvalidZeroShares.selector);
        vm.prank(user1);
        stakedYzusd.initiateRedeem(0);
    }

    function test_InitiateRedeem_RevertLimitExceeded() public {
        // Deposit
        uint256 depositSize = MAX_DEPOSIT_PER_BLOCK;
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);

        // Try to initiate redeem
        vm.expectRevert(abi.encodeWithSelector(MaxRedeemExceeded.selector, MAX_WITHDRAW_PER_BLOCK + 1, MAX_WITHDRAW_PER_BLOCK));
        vm.prank(user1);
        stakedYzusd.initiateRedeem(MAX_WITHDRAW_PER_BLOCK + 1);
    }
    
    function test_InitiateRedeem_RevertInsufficientShares() public {
        // Deposit
        uint256 depositSize = 200e18;
        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);

        // Try to initiate redeem
        vm.expectRevert(abi.encodeWithSelector(MaxRedeemExceeded.selector, shares + 1, shares));
        vm.prank(user1);
        stakedYzusd.initiateRedeem(shares + 1);
    }

    // Redeem Finalization
    function test_FinalizeRedeem() public {
        // Deposit and initiate redeem
        uint256 depositSize = 200e18;
        vm.startPrank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Fast forward past redeem delay
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + REDEEM_DELAY);
        
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        // Finalize redeem
        vm.expectEmit();
        emit RedeemFinalized(user2, orderId, user1, depositSize, shares);
        vm.expectEmit();
        emit Withdraw(user2, user1, user1, depositSize, shares);
        vm.prank(user2);
        stakedYzusd.finalizeRedeem(orderId);

        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore + depositSize);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
        assertEq(stakedYzusd.totalSupply(), 0);
        assertEq(stakedYzusd.totalAssets(), 0);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), 0);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertTrue(order.executed);
    }

    function test_FinalizeRedeem_RevertInvalidOrder() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, 999));
        stakedYzusd.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_RevertNotDue() public {
        // Deposit and initiate redeem
        uint256 depositSize = 200e18;
        vm.startPrank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Try to finalize redeem
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        stakedYzusd.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_RevertAlreadyExecuted() public {
        // Deposit and initiate redeem
        uint256 depositSize = 200e18;
        vm.startPrank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(shares);
        vm.stopPrank();

        // Fast forward and finalize redeem
        vm.warp(block.timestamp + REDEEM_DELAY);
        stakedYzusd.finalizeRedeem(orderId);

        // Try to finalize again
        vm.expectRevert(abi.encodeWithSelector(OrderAlreadyExecuted.selector, orderId));
        stakedYzusd.finalizeRedeem(orderId);
    }

    // ERC-4626 Override
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
        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositAmount, user1);
        assertEq(stakedYzusd.totalAssets(), initialAssets + depositAmount);
        
        vm.prank(user1);
        stakedYzusd.initiateRedeem(shares);

        assertEq(stakedYzusd.totalAssets(), initialAssets);
    }

    function test_MaxDeposit() public {
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositSize = 300e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);

        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK - depositSize);
    }

    function test_MaxMint() public {
        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositSize = 300e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);

        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK - depositSize);
    }

    function test_MaxMint_WithAccruedAssets() public {
        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositSize = 200e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);
        
        // Double the value of the shares
        yzusd.mint(address(stakedYzusd), depositSize);
        

        assertEq(stakedYzusd.maxMint(user1), (MAX_DEPOSIT_PER_BLOCK - depositSize) / 2);
    }

    function test_MaxWithdraw() public {
        assertEq(stakedYzusd.maxWithdraw(user1), 0);

        // Deposit
        uint256 depositSize = 200e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositSize, user1);

        // Limited by share value
        assertEq(stakedYzusd.maxWithdraw(user1), depositSize);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        // Limited by max withdraw per block
        assertEq(stakedYzusd.maxWithdraw(user1), MAX_WITHDRAW_PER_BLOCK);
    }

    function test_MaxRedeem() public {
        assertEq(stakedYzusd.maxRedeem(user1), 0);

        uint256 depositSize = 200e18;

        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);

        // Limited by shares
        assertEq(stakedYzusd.maxRedeem(user1), shares);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        // Limited by max withdraw per block
        assertEq(stakedYzusd.maxRedeem(user1), MAX_WITHDRAW_PER_BLOCK);
    }

    function test_MaxRedeem_WithAccruedAssets() public {
        assertEq(stakedYzusd.maxRedeem(user1), 0);

        // Deposit
        uint256 depositSize = 200e18;
        vm.prank(user1);
        uint256 shares = stakedYzusd.deposit(depositSize, user1);

        // Double the value of the shares
        yzusd.mint(address(stakedYzusd), depositSize);

        assertEq(stakedYzusd.maxRedeem(user1), shares);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        assertEq(stakedYzusd.maxRedeem(user1), MAX_WITHDRAW_PER_BLOCK / 2);
    }

    // Integration
    function test_MultipleUsersDepositAndRedeem() public {
        // User1 deposits
        uint256 depositSize1 = 200e18;
        vm.prank(user1);
        uint256 shares1 = stakedYzusd.deposit(depositSize1, user1);

        // User2 deposits
        uint256 depositSize2 = 300e18;
        vm.prank(user2);
        uint256 shares2 = stakedYzusd.deposit(depositSize2, user2);

        // User1 initiates redeem
        vm.prank(user1);
        (uint256 orderId1,) = stakedYzusd.initiateRedeem(shares1);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), shares2);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositSize1);
        assertEq(stakedYzusd.totalSupply(), depositSize2);
        assertEq(stakedYzusd.totalAssets(), depositSize2);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositSize1 + depositSize2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK - depositSize1 - depositSize2);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), shares2);
        assertEq(stakedYzusd.depositedPerBlock(block.number), depositSize1 + depositSize2);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), depositSize1);

        // Fast forward
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + REDEEM_DELAY);

        // User1 finalize redeem
        stakedYzusd.finalizeRedeem(orderId1);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), shares2);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
        assertEq(stakedYzusd.totalSupply(), depositSize2);
        assertEq(stakedYzusd.totalAssets(), depositSize2);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositSize2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), shares2);
        assertEq(stakedYzusd.depositedPerBlock(block.number), 0);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), 0);

        // User2 initiates redeem
        vm.prank(user2);
        (uint256 orderId2,) = stakedYzusd.initiateRedeem(shares2);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), 0);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositSize2);
        assertEq(stakedYzusd.totalSupply(), 0);
        assertEq(stakedYzusd.totalAssets(), 0);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositSize2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), 0);
        assertEq(stakedYzusd.depositedPerBlock(block.number), 0);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), depositSize2);

        // Fast forward
        vm.roll(block.number + 2);
        vm.warp(block.timestamp + REDEEM_DELAY * 2);

        // User2 finalize redeem
        stakedYzusd.finalizeRedeem(orderId2);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), 0);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
        assertEq(stakedYzusd.totalSupply(), 0);
        assertEq(stakedYzusd.totalAssets(), 0);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), 0);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), 0);
        assertEq(stakedYzusd.depositedPerBlock(block.number), 0);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), 0);
    }

    function test_DepositLimitResetsAcrossBlocks() public {
        // Fill block limit in first block
        vm.prank(user1);
        stakedYzusd.deposit(MAX_DEPOSIT_PER_BLOCK, user1);

        // Should fail to deposit more in same block
        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.deposit(1e18, user2);

        // Move to next block
        vm.roll(block.number + 1);

        // Should work in new block
        vm.prank(user2);
        stakedYzusd.deposit(1e18, user2);
    }

    function test_RedeemLimitResetsAcrossBlocks() public {
        // Fill block limit in first block
        vm.startPrank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);
        stakedYzusd.initiateRedeem(MAX_WITHDRAW_PER_BLOCK);
        vm.stopPrank();

        vm.prank(user2);
        stakedYzusd.deposit(1e18, user2);

        // Should fail to redeem more in same block
        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.initiateRedeem(1e18);

        // Move to next block
        vm.roll(block.number + 1);

        // Should work in new block
        vm.prank(user2);
        stakedYzusd.initiateRedeem(1e18);
    }

    function test_DonationAttack_NoProfit() public {
        address attacker = user1;
        address victim = user2;

        uint256 attackerDepositSize = 1e18;
        uint256 attackerDonationSize = 100_000_000e18;
        uint256 victimDepositSize = 1e18;

        vm.startPrank(owner);
        stakedYzusd.setMaxDepositPerBlock(type(uint256).max);
        stakedYzusd.setMaxWithdrawPerBlock(type(uint256).max);
        vm.stopPrank();

        // Attacker deposits
        vm.prank(attacker);
        uint256 attackerShares = stakedYzusd.deposit(attackerDepositSize, attacker);

        // Attacker donates underlying directly to the vault
        yzusd.mint(address(stakedYzusd), attackerDonationSize);

        // Victim deposits
        vm.prank(victim);
        stakedYzusd.deposit(victimDepositSize, victim);

        // Attacker tries to profit by redeeming
        vm.prank(attacker);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(attackerShares);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);

        assertLe(order.assets, attackerDepositSize + attackerDonationSize);
        assertEq(order.shares, attackerShares);
    }
}
