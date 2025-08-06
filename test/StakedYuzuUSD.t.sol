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
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

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
        uint256 newMaxDepositPerBlock = 2_000e18;

        vm.expectEmit();
        emit MaxDepositPerBlockUpdated(MAX_DEPOSIT_PER_BLOCK, newMaxDepositPerBlock);
        vm.prank(owner);
        stakedYzusd.setMaxDepositPerBlock(newMaxDepositPerBlock);

        assertEq(stakedYzusd.maxDepositPerBlock(), newMaxDepositPerBlock);
    }

    function test_SetMaxDepositPerBlock_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setMaxDepositPerBlock(2_000e18);
    }

    function test_SetMaxDepositPerBlock_ZeroValue() public {
        uint256 newMaxDepositPerBlock = 0;

        vm.expectEmit();
        emit MaxDepositPerBlockUpdated(MAX_DEPOSIT_PER_BLOCK, newMaxDepositPerBlock);
        vm.prank(owner);
        stakedYzusd.setMaxDepositPerBlock(newMaxDepositPerBlock);

        assertEq(stakedYzusd.maxDepositPerBlock(), newMaxDepositPerBlock);
        assertEq(stakedYzusd.maxDeposit(user1), 0);
    }

    function test_SetMaxWithdrawPerBlock() public {
        uint256 newMaxWithdrawPerBlock = 1_000e18;

        vm.expectEmit();
        emit MaxWithdrawPerBlockUpdated(MAX_WITHDRAW_PER_BLOCK, newMaxWithdrawPerBlock);
        vm.prank(owner);
        stakedYzusd.setMaxWithdrawPerBlock(newMaxWithdrawPerBlock);

        assertEq(stakedYzusd.maxWithdrawPerBlock(), newMaxWithdrawPerBlock);
    }

    function test_SetMaxWithdrawPerBlock_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setMaxWithdrawPerBlock(1_000e18);
    }

    function test_SetMaxWithdrawPerBlock_ZeroValue() public {
        uint256 newMaxWithdrawPerBlock = 0;

        vm.expectEmit();
        emit MaxWithdrawPerBlockUpdated(MAX_WITHDRAW_PER_BLOCK, newMaxWithdrawPerBlock);
        vm.prank(owner);
        stakedYzusd.setMaxWithdrawPerBlock(newMaxWithdrawPerBlock);

        assertEq(stakedYzusd.maxWithdrawPerBlock(), newMaxWithdrawPerBlock);

        vm.prank(user1);
        stakedYzusd.deposit(100e18, user1);

        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxRedeem(user1), 0);
    }

    function test_SetRedeemDelay() public {
        uint256 newRedeemDelay = 2 days;

        vm.expectEmit();
        emit RedeemDelayUpdated(REDEEM_DELAY, newRedeemDelay);
        vm.prank(owner);
        stakedYzusd.setRedeemDelay(newRedeemDelay);

        assertEq(stakedYzusd.redeemDelay(), newRedeemDelay);
    }

    function test_SetRedeemDelay_RevertOnlyOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.setRedeemDelay(2 days);
    }

    function test_SetRedeemDelay_ZeroValue() public {
        uint256 newRedeemDelay = 0;

        vm.expectEmit();
        emit RedeemDelayUpdated(REDEEM_DELAY, newRedeemDelay);
        vm.prank(owner);
        stakedYzusd.setRedeemDelay(newRedeemDelay);

        assertEq(stakedYzusd.redeemDelay(), newRedeemDelay);

        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(100e18, user1);

        vm.prank(user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(mintedShares);

        stakedYzusd.finalizeRedeem(orderId);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertTrue(order.executed);
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

    function test_RescueTokens_ZeroAmount() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 0;
        uint256 balanceBefore = otherToken.balanceOf(user1);

        vm.prank(owner);
        stakedYzusd.rescueTokens(address(otherToken), user1, amount);

        assertEq(otherToken.balanceOf(user1), balanceBefore);
    }

    function test_RescueTokens_RevertZeroAddress() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 100e18;
        otherToken.mint(address(stakedYzusd), amount);

        // Test with zero address as recipient - should revert on transfer
        vm.expectRevert();
        vm.prank(owner);
        stakedYzusd.rescueTokens(address(otherToken), address(0), amount);
    }

    // Deposit
    function test_Deposit() public {
        uint256 depositAmount = 200e18;
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, depositAmount, depositAmount);
        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);

        assertEq(stakedYzusd.balanceOf(user1), mintedShares);
        assertEq(stakedYzusd.totalSupply(), mintedShares);
        assertEq(stakedYzusd.totalAssets(), mintedShares);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositAmount);
        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore - depositAmount);
        assertEq(stakedYzusd.depositedPerBlock(block.number), depositAmount);
    }

    function test_Deposit_RevertLimitExceeded() public {
        uint256 depositAmount = MAX_DEPOSIT_PER_BLOCK + 1;

        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);
    }

    function test_Deposit_MultipleInSameBlock_RevertLimitExceeded() public {
        uint256 depositAmount1 = MAX_DEPOSIT_PER_BLOCK;
        uint256 depositAmount2 = 200e18;

        vm.prank(user1);
        stakedYzusd.deposit(depositAmount1, user1);

        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.deposit(depositAmount2, user2);
    }

    // Mint
    function test_Mint() public {
        uint256 mintAmount = 200e18;
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        vm.expectEmit();
        emit Deposit(user1, user1, mintAmount, mintAmount);
        vm.prank(user1);
        uint256 assets = stakedYzusd.mint(mintAmount, user1);

        assertEq(assets, mintAmount);
        assertEq(stakedYzusd.balanceOf(user1), assets);
        assertEq(stakedYzusd.totalSupply(), assets);
        assertEq(stakedYzusd.totalAssets(), assets);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), assets);
        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore - assets);
        assertEq(stakedYzusd.depositedPerBlock(block.number), assets);
    }

    function test_Mint_RevertLimitExceeded() public {
        uint256 mintAmount = MAX_DEPOSIT_PER_BLOCK + 1;

        vm.expectRevert();
        vm.prank(user1);
        stakedYzusd.mint(mintAmount, user1);
    }

    function test_Mint_MultipleInSameBlock_RevertLimitExceeded() public {
        uint256 mintAmount1 = MAX_DEPOSIT_PER_BLOCK;
        uint256 mintAmount2 = 200e18;

        vm.prank(user1);
        stakedYzusd.mint(mintAmount1, user1);

        vm.expectRevert();
        vm.prank(user2);
        stakedYzusd.mint(mintAmount2, user2);
    }

    // Redeem Initiation
    function test_InitiateRedeem() public {
        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);

        // Initiate redeem
        vm.expectEmit();
        emit RedeemInitiated(0, user1, depositAmount, mintedShares);
        vm.prank(user1);
        (uint256 orderId, uint256 _assets) = stakedYzusd.initiateRedeem(mintedShares);

        assertEq(orderId, 0);
        assertEq(_assets, depositAmount);
        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositAmount);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);
        assertEq(order.assets, depositAmount);
        assertEq(order.shares, mintedShares);
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
        uint256 depositAmount = MAX_DEPOSIT_PER_BLOCK;
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);

        // Try to initiate redeem
        vm.expectRevert(
            abi.encodeWithSelector(MaxRedeemExceeded.selector, MAX_WITHDRAW_PER_BLOCK + 1, MAX_WITHDRAW_PER_BLOCK)
        );
        vm.prank(user1);
        stakedYzusd.initiateRedeem(MAX_WITHDRAW_PER_BLOCK + 1);
    }

    function test_InitiateRedeem_RevertInsufficientShares() public {
        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);

        // Try to initiate redeem
        vm.expectRevert(abi.encodeWithSelector(MaxRedeemExceeded.selector, mintedShares + 1, mintedShares));
        vm.prank(user1);
        stakedYzusd.initiateRedeem(mintedShares + 1);
    }

    // Redeem Finalization
    function test_FinalizeRedeem() public {
        // Deposit and initiate redeem
        uint256 depositAmount = 200e18;
        vm.startPrank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(mintedShares);
        vm.stopPrank();

        // Fast forward past redeem delay
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + REDEEM_DELAY);

        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        // Finalize redeem
        vm.expectEmit();
        emit RedeemFinalized(user2, orderId, user1, depositAmount, mintedShares);
        vm.expectEmit();
        emit Withdraw(user2, user1, user1, depositAmount, mintedShares);
        vm.prank(user2);
        stakedYzusd.finalizeRedeem(orderId);

        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore + depositAmount);
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
        uint256 depositAmount = 200e18;
        vm.startPrank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(mintedShares);
        vm.stopPrank();

        // Try to finalize redeem
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        stakedYzusd.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_RevertAlreadyExecuted() public {
        // Deposit and initiate redeem
        uint256 depositAmount = 200e18;
        vm.startPrank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(mintedShares);
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
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);
        assertEq(stakedYzusd.totalAssets(), initialAssets + depositAmount);

        vm.prank(user1);
        stakedYzusd.initiateRedeem(mintedShares);

        assertEq(stakedYzusd.totalAssets(), initialAssets);
    }

    function test_MaxDeposit() public {
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositAmount = 300e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);

        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK - depositAmount);
    }

    function test_MaxMint() public {
        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositAmount = 300e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);

        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK - depositAmount);
    }

    function test_MaxMint_WithAccruedAssets() public {
        assertEq(stakedYzusd.maxMint(user1), MAX_DEPOSIT_PER_BLOCK);

        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);

        // Double the value of the shares
        yzusd.mint(address(stakedYzusd), depositAmount);

        assertEq(stakedYzusd.maxMint(user1), (MAX_DEPOSIT_PER_BLOCK - depositAmount) / 2);
    }

    function test_MaxWithdraw() public {
        assertEq(stakedYzusd.maxWithdraw(user1), 0);

        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        stakedYzusd.deposit(depositAmount, user1);

        // Limited by share value
        assertEq(stakedYzusd.maxWithdraw(user1), depositAmount);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        // Limited by max withdraw per block
        assertEq(stakedYzusd.maxWithdraw(user1), MAX_WITHDRAW_PER_BLOCK);
    }

    function test_MaxRedeem() public {
        assertEq(stakedYzusd.maxRedeem(user1), 0);

        uint256 depositAmount = 200e18;

        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);

        // Limited by shares
        assertEq(stakedYzusd.maxRedeem(user1), mintedShares);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        // Limited by max withdraw per block
        assertEq(stakedYzusd.maxRedeem(user1), MAX_WITHDRAW_PER_BLOCK);
    }

    function test_MaxRedeem_WithAccruedAssets() public {
        assertEq(stakedYzusd.maxRedeem(user1), 0);

        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        uint256 mintedShares = stakedYzusd.deposit(depositAmount, user1);

        // Double the value of the shares
        yzusd.mint(address(stakedYzusd), depositAmount);

        assertEq(stakedYzusd.maxRedeem(user1), mintedShares);

        vm.prank(user1);
        stakedYzusd.deposit(MAX_WITHDRAW_PER_BLOCK, user1);

        assertEq(stakedYzusd.maxRedeem(user1), MAX_WITHDRAW_PER_BLOCK / 2);
    }

    // Integration
    function test_MultipleUsersDepositAndRedeem() public {
        // User1 deposits
        uint256 depositAmount1 = 200e18;
        vm.prank(user1);
        uint256 mintedShares1 = stakedYzusd.deposit(depositAmount1, user1);

        // User2 deposits
        uint256 depositAmount2 = 300e18;
        vm.prank(user2);
        uint256 mintedShares2 = stakedYzusd.deposit(depositAmount2, user2);

        // User1 initiates redeem
        vm.prank(user1);
        (uint256 orderId1,) = stakedYzusd.initiateRedeem(mintedShares1);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), mintedShares2);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositAmount1);
        assertEq(stakedYzusd.totalSupply(), depositAmount2);
        assertEq(stakedYzusd.totalAssets(), depositAmount2);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositAmount1 + depositAmount2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK - depositAmount1 - depositAmount2);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), mintedShares2);
        assertEq(stakedYzusd.depositedPerBlock(block.number), depositAmount1 + depositAmount2);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), depositAmount1);

        // Fast forward
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + REDEEM_DELAY);

        // User1 finalize redeem
        stakedYzusd.finalizeRedeem(orderId1);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), mintedShares2);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), 0);
        assertEq(stakedYzusd.totalSupply(), depositAmount2);
        assertEq(stakedYzusd.totalAssets(), depositAmount2);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositAmount2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), mintedShares2);
        assertEq(stakedYzusd.depositedPerBlock(block.number), 0);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), 0);

        // User2 initiates redeem
        vm.prank(user2);
        (uint256 orderId2,) = stakedYzusd.initiateRedeem(mintedShares2);

        assertEq(stakedYzusd.balanceOf(user1), 0);
        assertEq(stakedYzusd.balanceOf(user2), 0);
        assertEq(stakedYzusd.currentRedeemAssetCommitment(), depositAmount2);
        assertEq(stakedYzusd.totalSupply(), 0);
        assertEq(stakedYzusd.totalAssets(), 0);
        assertEq(yzusd.balanceOf(address(stakedYzusd)), depositAmount2);
        assertEq(stakedYzusd.maxDeposit(user1), MAX_DEPOSIT_PER_BLOCK);
        assertEq(stakedYzusd.maxWithdraw(user1), 0);
        assertEq(stakedYzusd.maxWithdraw(user2), 0);
        assertEq(stakedYzusd.depositedPerBlock(block.number), 0);
        assertEq(stakedYzusd.withdrawnPerBlock(block.number), depositAmount2);

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

    function test_Deposit_LimitResetsAcrossBlocks() public {
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

    function test_Redeem_LimitResetsAcrossBlocks() public {
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

        uint256 attackerDepositAmount = 1e18;
        uint256 attackerDonationAmount = 100_000_000e18;
        uint256 victimDepositAmount = 1e18;

        vm.startPrank(owner);
        stakedYzusd.setMaxDepositPerBlock(type(uint256).max);
        stakedYzusd.setMaxWithdrawPerBlock(type(uint256).max);
        vm.stopPrank();

        // Attacker deposits
        vm.prank(attacker);
        uint256 attackerShares = stakedYzusd.deposit(attackerDepositAmount, attacker);

        // Attacker donates underlying directly to the vault
        yzusd.mint(address(stakedYzusd), attackerDonationAmount);

        // Victim deposits
        vm.prank(victim);
        stakedYzusd.deposit(victimDepositAmount, victim);

        // Attacker tries to profit by redeeming
        vm.prank(attacker);
        (uint256 orderId,) = stakedYzusd.initiateRedeem(attackerShares);

        Order memory order = stakedYzusd.getRedeemOrder(orderId);

        assertLe(order.assets, attackerDepositAmount + attackerDonationAmount);
        assertEq(order.shares, attackerShares);
    }
}
