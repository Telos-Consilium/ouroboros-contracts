// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Order, OrderStatus} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IStakedYuzuUSDDefinitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";

import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

contract StakedYuzuUSDTest is IStakedYuzuUSDDefinitions, Test {
    // ERC-4626
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    error ERC4626ExceededMaxDeposit(address owner, uint256 assets, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address owner, uint256 shares, uint256 max);

    // Ownable
    error OwnableUnauthorizedAccount(address account);

    StakedYuzuUSD public styz;
    ERC20Mock public yzusd;
    address public owner;
    address public user1;
    address public user2;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock asset and mint balances
        yzusd = new ERC20Mock();
        yzusd.mint(user1, 1_000_000e18);
        yzusd.mint(user2, 1_000_000e18);

        // Deploy implementation and proxy-initialize
        StakedYuzuUSD implementation = new StakedYuzuUSD();
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            owner,
            1_000_000e18,
            1_000_000e18,
            1 days
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        styz = StakedYuzuUSD(address(proxy));

        // Approvals for deposits/orders
        vm.prank(user1);
        yzusd.approve(address(styz), type(uint256).max);
        vm.prank(user2);
        yzusd.approve(address(styz), type(uint256).max);
    }

    // Helpers
    function _deposit(address from, uint256 amount) internal returns (uint256 tokens) {
        vm.prank(from);
        return styz.deposit(amount, from);
    }

    function _withdraw(address from, uint256 amount) internal returns (uint256 withdrawnAssets) {
        vm.prank(from);
        return styz.withdraw(amount, from, from);
    }

    function _setMaxDepositPerBlock(uint256 maxDepositPerBlock) internal {
        vm.prank(owner);
        styz.setMaxDepositPerBlock(maxDepositPerBlock);
    }

    function _setMaxWithdrawPerBlock(uint256 maxWithdrawPerBlock) internal {
        vm.prank(owner);
        styz.setMaxWithdrawPerBlock(maxWithdrawPerBlock);
    }

    // Initialization
    function test_Initialize() public {
        assertEq(address(styz.asset()), address(yzusd));
        assertEq(styz.name(), "Staked Yuzu USD");
        assertEq(styz.symbol(), "st-yzUSD");
        assertEq(styz.owner(), owner);
        assertEq(styz.maxDepositPerBlock(), 1_000_000e18);
        assertEq(styz.maxWithdrawPerBlock(), 1_000_000e18);
        assertEq(styz.redeemDelay(), 1 days);
    }

    // Max functions
    function test_MaxDeposit_MaxMint() public {
        _setMaxDepositPerBlock(0);

        assertEq(styz.maxDeposit(user1), 0);
        assertEq(styz.maxMint(user1), 0);

        _setMaxDepositPerBlock(100e18);

        assertEq(styz.maxDeposit(user1), 100e18);
        assertEq(styz.maxMint(user1), 100e18);
    }

    function test_MaxWithdraw_MaxRedeem() public {
        vm.prank(owner);
        styz.setRedeemFee(100_000); // 10%

        _setMaxWithdrawPerBlock(0);

        // Limited by max, balance
        assertEq(styz.maxWithdraw(user1), 0);
        assertEq(styz.maxRedeem(user1), 0);

        _setMaxWithdrawPerBlock(100e18);

        // Limited by balance
        assertEq(styz.maxWithdraw(user1), 0);
        assertEq(styz.maxRedeem(user1), 0);

        _deposit(user1, 200e18);

        // Limited by max
        assertEq(styz.maxWithdraw(user1), 100e18);
        assertEq(styz.maxRedeem(user1), 110e18);
    }

    // Deposit
    function test_Deposit() public {
        address sender = user1;
        address receiver = user2;

        uint256 depositAmount = 100e18;
        uint256 expectedTokens = 100e18;

        assertEq(styz.previewDeposit(depositAmount), expectedTokens);

        uint256 senderYzUSDBefore = yzusd.balanceOf(sender);
        uint256 receiverYzUSDBefore = yzusd.balanceOf(receiver);
        uint256 treasuryYzUSDBefore = yzusd.balanceOf(address(styz));

        uint256 senderSharesBefore = styz.balanceOf(sender);
        uint256 receiverSharesBefore = styz.balanceOf(receiver);

        uint256 supplyBefore = styz.totalSupply();
        uint256 depositedPerBlockBefore = styz.depositedPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Deposit(sender, receiver, depositAmount, expectedTokens);
        uint256 mintedTokens = styz.deposit(depositAmount, receiver);

        assertEq(mintedTokens, expectedTokens);

        assertEq(yzusd.balanceOf(sender), senderYzUSDBefore - depositAmount);
        assertEq(yzusd.balanceOf(receiver), receiverYzUSDBefore);
        assertEq(yzusd.balanceOf(address(styz)), treasuryYzUSDBefore + depositAmount);

        assertEq(styz.balanceOf(sender), senderSharesBefore);
        assertEq(styz.balanceOf(receiver), receiverSharesBefore + expectedTokens);

        assertEq(styz.totalSupply(), supplyBefore + mintedTokens);
        assertEq(styz.depositedPerBlock(block.number), depositedPerBlockBefore + depositAmount);
    }

    function test_Deposit_Revert_ExceedsMaxDeposit() public {
        _setMaxDepositPerBlock(100e18);

        vm.expectRevert(abi.encodeWithSelector(ERC4626ExceededMaxDeposit.selector, user2, 100e18 + 1, 100e18));
        vm.prank(user1);
        styz.deposit(100e18 + 1, user2);
    }

    // Mint
    function test_Mint() public {
        address sender = user1;
        address receiver = user2;

        uint256 mintAmount = 100e18;
        uint256 expectedAssets = 100e18;

        assertEq(styz.previewMint(mintAmount), expectedAssets);

        uint256 senderYzUSDBefore = yzusd.balanceOf(sender);
        uint256 receiverYzUSDBefore = yzusd.balanceOf(receiver);
        uint256 treasuryYzUSDBefore = yzusd.balanceOf(address(styz));

        uint256 senderSharesBefore = styz.balanceOf(sender);
        uint256 receiverSharesBefore = styz.balanceOf(receiver);

        uint256 supplyBefore = styz.totalSupply();
        uint256 depositedPerBlockBefore = styz.depositedPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Deposit(sender, receiver, expectedAssets, mintAmount);
        uint256 depositedAssets = styz.deposit(expectedAssets, receiver);

        assertEq(depositedAssets, mintAmount);

        assertEq(yzusd.balanceOf(sender), senderYzUSDBefore - expectedAssets);
        assertEq(yzusd.balanceOf(receiver), receiverYzUSDBefore);
        assertEq(yzusd.balanceOf(address(styz)), treasuryYzUSDBefore + expectedAssets);

        assertEq(styz.balanceOf(sender), senderSharesBefore);
        assertEq(styz.balanceOf(receiver), receiverSharesBefore + mintAmount);

        assertEq(styz.totalSupply(), supplyBefore + mintAmount);
        assertEq(styz.depositedPerBlock(block.number), depositedPerBlockBefore + expectedAssets);
    }

    function test_Mint_Revert_ExceedsMaxMint() public {
        _setMaxDepositPerBlock(100e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626ExceededMaxMint.selector, user2, 100e18 + 1, 100e18));
        styz.mint(100e18 + 1, user2);
    }

    // Redeem Initiation
    function test_InitiateRedeem() public {
        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);

        // Initiate redeem
        vm.expectEmit();
        emit InitiatedRedeem(user1, user1, user1, 0, depositAmount, mintedShares);
        vm.prank(user1);
        (uint256 orderId, uint256 _assets) = styz.initiateRedeem(mintedShares, user1, user1);

        assertEq(orderId, 0);
        assertEq(_assets, depositAmount);
        assertEq(styz.balanceOf(user1), 0);
        assertEq(styz.currentPendingOrderValue(), depositAmount);

        Order memory order = styz.getRedeemOrder(orderId);
        assertEq(order.assets, depositAmount);
        assertEq(order.shares, mintedShares);
        assertEq(order.owner, user1);
        assertEq(order.dueTime, block.timestamp + styz.redeemDelay());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    // function test_InitiateRedeem_RevertZeroShares() public {
    //     vm.expectRevert(InvalidZeroShares.selector);
    //     vm.prank(user1);
    //     styz.initiateRedeem(0, user1, user1);
    // }

    // function test_InitiateRedeem_RevertLimitExceeded() public {
    //     // Deposit
    //     uint256 depositAmount = MAX_DEPOSIT_PER_BLOCK;
    //     vm.prank(user1);
    //     styz.deposit(depositAmount, user1);

    //     // Try to initiate redeem
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             ERC4626ExceededMaxRedeem.selector, user1, MAX_WITHDRAW_PER_BLOCK + 1, MAX_WITHDRAW_PER_BLOCK
    //         )
    //     );
    //     vm.prank(user1);
    //     styz.initiateRedeem(MAX_WITHDRAW_PER_BLOCK + 1, user1, user1);
    // }

    function test_InitiateRedeem_Revert_InsufficientShares() public {
        // Deposit
        uint256 depositAmount = 200e18;
        vm.prank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);

        // Try to initiate redeem
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626ExceededMaxRedeem.selector, user1, mintedShares + 1, mintedShares)
        );
        vm.prank(user1);
        styz.initiateRedeem(mintedShares + 1, user1, user1);
    }

    // Redeem Finalization
    function test_FinalizeRedeem() public {
        // Deposit and initiate redeem
        uint256 depositAmount = 200e18;
        vm.startPrank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, user1, user1);
        vm.stopPrank();

        // Fast forward past redeem delay
        vm.warp(block.timestamp + styz.redeemDelay());

        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        // Finalize redeem
        vm.expectEmit();
        emit FinalizedRedeem(user2, user1, user1, orderId, depositAmount, mintedShares);
        vm.expectEmit();
        emit Withdraw(user2, user1, user1, depositAmount, mintedShares);
        vm.prank(user2);
        styz.finalizeRedeem(orderId);

        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore + depositAmount);
        assertEq(styz.currentPendingOrderValue(), 0);
        assertEq(styz.totalSupply(), 0);
        assertEq(styz.totalAssets(), 0);
        assertEq(yzusd.balanceOf(address(styz)), 0);

        Order memory order = styz.getRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Executed));
    }

    function test_FinalizeRedeem_Revert_InvalidOrder() public {
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, 999));
        styz.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_Revert_NotDue() public {
        // Deposit and initiate redeem
        uint256 depositAmount = 200e18;
        vm.startPrank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, user1, user1);
        vm.stopPrank();

        // Try to finalize redeem
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_Revert_AlreadyExecuted() public {
        // Deposit and initiate redeem
        uint256 depositAmount = 100e18;
        vm.startPrank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, user1, user1);
        vm.stopPrank();

        // Fast forward and finalize redeem
        vm.warp(block.timestamp + styz.redeemDelay());
        styz.finalizeRedeem(orderId);

        // Try to finalize again
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    // Admin Functions
    function test_RescueTokens() public {
        ERC20Mock otherAsset = new ERC20Mock();
        otherAsset.mint(address(styz), 100e18);
        uint256 balanceBefore = otherAsset.balanceOf(user1);

        vm.prank(owner);
        styz.rescueTokens(address(otherAsset), user1, 50e18);

        assertEq(otherAsset.balanceOf(user1), balanceBefore + 50e18);
        assertEq(otherAsset.balanceOf(address(styz)), 50e18);
    }

    function test_RescueTokens_UnderlyingToken() public {
        _deposit(user1, 100e18);

        vm.prank(user1);
        styz.transfer(address(styz), 100e18);

        uint256 balanceBefore = styz.balanceOf(user1);

        vm.prank(owner);
        styz.rescueTokens(address(styz), user1, 100e18);

        assertEq(styz.balanceOf(user1), balanceBefore + 100e18);
        assertEq(styz.balanceOf(address(styz)), 0);
    }

    function test_RescueToken_Revert_UnderlyingAsset() public {
        yzusd.mint(address(styz), 100e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidAssetRescue.selector, address(yzusd)));
        styz.rescueTokens(address(yzusd), user1, 100e18);
    }

    function test_RescueTokens_Revert_NotOwner() public {
        ERC20Mock otherAsset = new ERC20Mock();
        otherAsset.mint(address(styz), 100e18);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.rescueTokens(address(otherAsset), user1, 50e18);
    }

    function test_setRedeemFee() public {
        vm.prank(owner);
        vm.expectEmit();
        emit UpdatedRedeemOrderFee(0, 1_000_000);
        styz.setRedeemFee(1_000_000);
        assertEq(styz.redeemOrderFeePpm(), 1_000_000);
    }

    function test_setRedeemFee_Revert_ExceedsMaxFee() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidRedeemOrderFee.selector, 1_000_001));
        styz.setRedeemFee(1_000_001);
    }

    function test_setRedeemFee_Revert_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setRedeemFee(100_000);
    }

    function test_SetMaxDepositPerBlock() public {
        vm.prank(owner);
        vm.expectEmit();
        emit UpdatedMaxDepositPerBlock(1_000_000e18, 200e18);
        styz.setMaxDepositPerBlock(200e18);
        assertEq(styz.maxDepositPerBlock(), 200e18);
    }

    function test_SetMaxDepositPerBlock_Revert_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setMaxDepositPerBlock(200e18);
    }

    function test_SetMaxWithdrawPerBlock() public {
        vm.prank(owner);
        vm.expectEmit();
        emit UpdatedMaxWithdrawPerBlock(1_000_000e18, 200e18);
        styz.setMaxWithdrawPerBlock(200e18);
        assertEq(styz.maxWithdrawPerBlock(), 200e18);
    }

    function test_SetMaxWithdrawPerBlock_Revert_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setMaxWithdrawPerBlock(200e18);
    }

    function test_SetRedeemDelay() public {
        vm.prank(owner);
        vm.expectEmit();
        emit UpdatedRedeemDelay(1 days, 2 days);
        styz.setRedeemDelay(2 days);
        assertEq(styz.redeemDelay(), 2 days);
    }

    function test_SetRedeemDelay_Revert_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setRedeemDelay(2 days);
    }

    // ERC-4626 Override
    function test_Withdraw_Revert() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        styz.withdraw(100e18, user1, user1);
    }

    function test_Redeem_Revert() public {
        vm.expectRevert(RedeemNotSupported.selector);
        styz.redeem(100e18, user1, user1);
    }

    function test_TotalAssets_WithCommitment() public {
        uint256 initialAssets = styz.totalAssets();

        // Deposit and initiate redeem
        uint256 depositAmount = 100e18;
        vm.prank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);
        assertEq(styz.totalAssets(), initialAssets + depositAmount);

        vm.prank(user1);
        styz.initiateRedeem(mintedShares, user1, user1);

        assertEq(styz.totalAssets(), initialAssets);
    }

    function test_PreviewRedeem_WithAccruedAssets() public {
        assertEq(styz.maxRedeem(user1), 0);

        // Deposit
        uint256 depositAmount = 100e18;
        uint256 mintedShares = _deposit(user1, depositAmount);

        // Double the value of the shares
        yzusd.mint(address(styz), depositAmount);

        assertEq(styz.maxRedeem(user1), mintedShares);
        assertEq(styz.previewRedeem(1e18), 2e18 - 1);
    }

    // function test_Deposit_LimitResetsAcrossBlocks() public {
    //     // Fill block limit in first block
    //     vm.prank(user1);
    //     styz.deposit(MAX_DEPOSIT_PER_BLOCK, user1);

    //     // Should fail to deposit more in same block
    //     vm.expectRevert();
    //     vm.prank(user2);
    //     styz.deposit(1e18, user2);

    //     // Move to next block
    //     vm.roll(block.number + 1);

    //     // Should work in new block
    //     vm.prank(user2);
    //     styz.deposit(1e18, user2);
    // }

    // function test_Redeem_LimitResetsAcrossBlocks() public {
    //     // Fill block limit in first block
    //     vm.startPrank(user1);
    //     styz.deposit(MAX_WITHDRAW_PER_BLOCK, user1);
    //     styz.initiateRedeem(MAX_WITHDRAW_PER_BLOCK, user1, user1);
    //     vm.stopPrank();

    //     vm.prank(user2);
    //     styz.deposit(1e18, user2);

    //     // Should fail to redeem more in same block
    //     vm.expectRevert();
    //     vm.prank(user2);
    //     styz.initiateRedeem(1e18, user2, user2);

    //     // Move to next block
    //     vm.roll(block.number + 1);

    //     // Should work in new block
    //     vm.prank(user2);
    //     styz.initiateRedeem(1e18, user2, user2);
    // }
}
