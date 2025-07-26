// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {Order} from "../src/YuzuILP.sol";
import {IYuzuILPDefinitions} from "../src/interfaces/IYuzuILPDefinitions.sol";

contract YuzuILPTest is IYuzuILPDefinitions, Test {
    YuzuILP public ilp;
    ERC20Mock public asset;

    address public admin;
    address public treasury;
    address public limitManager;
    address public orderFiller;
    address public poolManager;
    address public user1;
    address public user2;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    function setUp() public {
        // Set up addresses
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        limitManager = makeAddr("limitManager");
        orderFiller = makeAddr("orderFiller");
        poolManager = makeAddr("poolManager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock asset
        asset = new ERC20Mock();

        // Mint assets to users
        asset.mint(user1, 10_000e18);
        asset.mint(user2, 10_000e18);
        asset.mint(orderFiller, 10_000e18);

        // Deploy YuzuILP
        vm.prank(admin);
        ilp = new YuzuILP(IERC20(address(asset)), admin, treasury, 0);

        // Set up roles
        vm.startPrank(admin);
        ilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        ilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        ilp.grantRole(POOL_MANAGER_ROLE, poolManager);
        ilp.setTreasury(treasury);
        vm.stopPrank();
    }

    function _updatePool(uint256 poolSize, uint256 withdrawAllowance, uint256 dailyLinearYieldRatePpm) internal {
        vm.prank(poolManager);
        ilp.updatePool(poolSize, withdrawAllowance, dailyLinearYieldRatePpm);
    }

    function _setMaxDepositPerBlock(uint256 maxMint) internal {
        vm.prank(limitManager);
        ilp.setMaxDepositPerBlock(maxMint);
    }

    // Constructor Tests
    function test_Constructor_Success() public {
        uint256 maxDepositPerBlock = 1_000e18;
        YuzuILP newIlp = new YuzuILP(IERC20(address(asset)), admin, treasury, maxDepositPerBlock);

        assertEq(address(newIlp.asset()), address(asset));
        assertEq(newIlp.name(), "Yuzu ILP");
        assertEq(newIlp.symbol(), "yzILP");
        assertEq(newIlp.treasury(), treasury);
        assertEq(newIlp.maxDepositPerBlock(), maxDepositPerBlock);
        assertTrue(newIlp.hasRole(ADMIN_ROLE, admin));
        assertTrue(newIlp.hasRole(newIlp.DEFAULT_ADMIN_ROLE(), admin));
    }

    // Role Management Tests
    function test_SetMaxDepositPerBlock_Success() public {
        uint256 newMaxDepositPerBlock = 2_000e18;

        vm.prank(limitManager);
        ilp.setMaxDepositPerBlock(newMaxDepositPerBlock);

        assertEq(ilp.maxDepositPerBlock(), newMaxDepositPerBlock);
    }

    function test_SetMaxDepositPerBlock_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        ilp.setMaxDepositPerBlock(2_000e18);
    }

    function test_SetTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(admin);
        ilp.setTreasury(newTreasury);

        assertEq(ilp.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertInvalidZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidZeroAddress.selector));
        ilp.setTreasury(address(0));
    }

    function test_SetTreasury_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        ilp.setTreasury(makeAddr("newTreasury"));
    }

    function test_UpdatePool_Success() public {
        uint256 newPoolSize = 2_000e18;
        uint256 newWithdrawAllowance = 1_000e18;
        uint256 newYieldRate = 200_000; // 20% per day

        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawAllowance, newYieldRate);

        assertEq(ilp.poolSize(), newPoolSize);
        assertEq(ilp.withdrawAllowance(), newWithdrawAllowance);
        assertEq(ilp.dailyLinearYieldRatePpm(), newYieldRate);
        assertEq(ilp.lastPoolUpdateTimestamp(), block.timestamp);
    }

    function test_UpdatePool_RevertWithdrawalAllowanceExceedsPoolSize() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalAllowanceExceedsPoolSize.selector, 2_000e18));
        ilp.updatePool(1_000e18, 2_000e18, 0);
    }

    function test_UpdatePool_RevertUnauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        ilp.updatePool(2_000e18, 1_000e18, 0);
    }

    // Deposit Tests
    function test_Deposit_Success() public {
        uint256 depositAmount = 100e18;

        _setMaxDepositPerBlock(depositAmount);

        uint256 userSharesBefore = ilp.balanceOf(user1);
        uint256 treasuryBalanceBefore = asset.balanceOf(treasury);

        vm.startPrank(user1);
        asset.approve(address(ilp), depositAmount);
        uint256 shares = ilp.deposit(depositAmount, user1);
        vm.stopPrank();

        assertEq(ilp.balanceOf(user1), userSharesBefore + shares);
        assertEq(asset.balanceOf(treasury), treasuryBalanceBefore + depositAmount);

        assertEq(ilp.poolSize(), depositAmount);
        assertEq(ilp.totalAssets(), depositAmount);
        assertEq(ilp.totalSupply(), depositAmount);

        assertEq(ilp.depositedPerBlock(block.number), depositAmount);

        assertEq(ilp.withdrawAllowance(), depositAmount);
        assertEq(ilp.maxDeposit(user1), 0);
        assertEq(ilp.maxMint(user1), 0);
        assertEq(ilp.maxRedeem(user1), shares);
        assertEq(ilp.maxWithdraw(user1), depositAmount);
    }

    function test_Deposit_UpdatesStateWithYieldDiscount() public {
        uint256 depositAmount = 100e18;
        _setMaxDepositPerBlock(depositAmount);

        vm.startPrank(user1);
        asset.approve(address(ilp), depositAmount);
        ilp.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 dailyLinearYieldRatePpm = 250_000; // 25% daily yield
        _updatePool(depositAmount, 0, dailyLinearYieldRatePpm);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 days);

        uint256 poolSizeBefore = ilp.poolSize(); // 100e18 * 1.25 = 125e18
        uint256 totalAssetsBefore = ilp.totalAssets();

        vm.startPrank(user2);
        asset.approve(address(ilp), depositAmount);
        ilp.deposit(depositAmount, user2);
        vm.stopPrank();

        uint256 poolSizeAfter = ilp.poolSize();
        assertLt(poolSizeAfter - poolSizeBefore, depositAmount);
        assertGt(poolSizeAfter, poolSizeBefore);

        uint256 expectedPoolSizeIncrease = 80e18; // 100e18 / 1.25 = 80e18
        assertEq(poolSizeAfter, poolSizeBefore + expectedPoolSizeIncrease);

        uint256 totalAssetsAfter = ilp.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + depositAmount);
    }

    function test_MaxDeposit_RespectsMintLimit() public {
        _setMaxDepositPerBlock(1_000e18);

        vm.startPrank(user1);
        uint256 maxDeposit = ilp.maxDeposit(user1);
        asset.approve(address(ilp), maxDeposit);
        ilp.deposit(maxDeposit, user1);
        vm.stopPrank();

        assertEq(ilp.maxDeposit(user1), 0);
        assertEq(ilp.maxMint(user1), 0);
    }

    function test_Deposit_RevertExceedsMintLimit() public {
        uint256 maxDepositsPerBlock = 1_000e18;
        _setMaxDepositPerBlock(maxDepositsPerBlock);

        vm.startPrank(user1);
        asset.approve(address(ilp), maxDepositsPerBlock + 1);

        vm.expectRevert();
        ilp.deposit(maxDepositsPerBlock + 1, user1);
        vm.stopPrank();
    }

    // Total Assets Tests
    function test_TotalAssets_WithoutYield() public {
        assertEq(ilp.totalAssets(), ilp.poolSize());
    }

    function test_TotalAssets_WithYield() public {
        uint256 poolSize = 1_000e18;
        uint256 withdrawAllowance = 0;
        uint256 dailyLinearYieldRatePpm = 100_000; // 10%

        _updatePool(poolSize, withdrawAllowance, dailyLinearYieldRatePpm);

        // Move forward 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 expectedYield = 100e18;
        uint256 expectedTotal = poolSize + expectedYield;

        assertEq(ilp.totalAssets(), expectedTotal);
    }

    function test_TotalAssets_PartialDay() public {
        uint256 poolSize = 1_000e18;
        uint256 withdrawAllowance = 0;
        uint256 dailyLinearYieldRatePpm = 100_000; // 10%
        uint256 elapsedTime = 12 hours; // Half a day

        _updatePool(poolSize, withdrawAllowance, dailyLinearYieldRatePpm);

        // Move forward 12 hours (half day)
        vm.warp(block.timestamp + elapsedTime);

        uint256 expectedYield = 50e18;
        uint256 expectedTotal = poolSize + expectedYield;

        assertEq(ilp.totalAssets(), expectedTotal);
    }

    // Max Withdraw/Redeem Tests
    function test_MaxWithdraw_RespectsBalance() public {
        uint256 depositAmount = 100e18;

        _setMaxDepositPerBlock(depositAmount);

        vm.startPrank(user1);
        asset.approve(address(ilp), depositAmount);
        ilp.deposit(depositAmount, user1);
        vm.stopPrank();

        _updatePool(2 * depositAmount, 2 * depositAmount, 0);

        uint256 userShares = ilp.balanceOf(user1);
        uint256 maxWithdrawFromShares = ilp.convertToAssets(userShares);
        uint256 maxWithdraw = ilp.maxWithdraw(user1);
        assertEq(maxWithdraw, maxWithdrawFromShares);
    }

    function test_MaxRedeem_RespectsAllowance() public {
        uint256 depositAmount = 100e18;

        _setMaxDepositPerBlock(depositAmount);

        vm.startPrank(user1);
        asset.approve(address(ilp), depositAmount);
        ilp.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 withdrawAllowance = 50e18;
        _updatePool(depositAmount, withdrawAllowance, 0);

        uint256 maxRedeemFromAllowance = ilp.convertToShares(withdrawAllowance);
        uint256 maxRedeem = ilp.maxRedeem(user1);
        assertEq(maxRedeem, maxRedeemFromAllowance);
    }

    // Withdraw/Redeem Not Supported Tests
    function test_Withdraw_RevertWithdrawNotSupported() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        ilp.withdraw(100e18, user1, user1);
    }

    function test_Redeem_RevertRedeemNotSupported() public {
        vm.expectRevert(RedeemNotSupported.selector);
        ilp.redeem(100e18, user1, user1);
    }

    // Redeem Order Tests
    function test_CreateRedeemOrder_Success() public {
        _setMaxDepositPerBlock(1_000e18);

        // Deposit
        uint256 depositSize = 50e18;
        vm.startPrank(user1);
        asset.approve(address(ilp), depositSize);
        uint256 shares = ilp.deposit(depositSize, user1);
        vm.stopPrank();

        // Create redeem order
        vm.startPrank(user1);
        vm.expectEmit();
        emit RedeemOrderCreated(0, user1, depositSize, shares);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(shares);
        vm.stopPrank();

        assertEq(depositSize, assets);
        assertEq(ilp.totalAssets() / assets, ilp.totalSupply() / shares);
        assertEq(orderId, 0);
        assertEq(ilp.redeemOrderCount(), 1);

        Order memory order = ilp.getRedeemOrder(orderId);
        assertEq(order.assets, assets);
        assertEq(order.shares, shares);
        assertEq(order.owner, user1);
        assertFalse(order.executed);

        assertEq(ilp.balanceOf(user1), 0);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.withdrawAllowance(), 0);
    }

    function test_CreateRedeemOrder_RevertInvalidZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(InvalidZeroShares.selector);
        ilp.createRedeemOrder(0);
    }

    function test_CreateRedeemOrder_RevertMaxRedeemExceeded() public {
        _setMaxDepositPerBlock(1_000e18);

        vm.startPrank(user1);
        asset.approve(address(ilp), 100e18);
        ilp.deposit(100e18, user1);

        uint256 maxRedeem = ilp.maxRedeem(user1);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemExceeded.selector, maxRedeem + 1, maxRedeem));
        ilp.createRedeemOrder(maxRedeem + 1);
        vm.stopPrank();
    }

    function test_FillRedeemOrder_Success() public {
        uint256 depositAmount = 100e18;
        _setMaxDepositPerBlock(depositAmount);

        // Create redeem order
        vm.startPrank(user1);
        asset.approve(address(ilp), depositAmount);
        uint256 shares = ilp.deposit(depositAmount, user1);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(shares);
        vm.stopPrank();

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 fillerBalanceBefore = asset.balanceOf(orderFiller);

        // Fill the order
        vm.startPrank(orderFiller);
        asset.approve(address(ilp), assets);

        vm.expectEmit();
        emit RedeemOrderFilled(orderId, user1, orderFiller, assets, shares);
        ilp.fillRedeemOrder(orderId);
        vm.stopPrank();

        // Check balances
        assertEq(asset.balanceOf(user1), user1BalanceBefore + assets);
        assertEq(asset.balanceOf(orderFiller), fillerBalanceBefore - assets);

        // Check order is marked as executed
        Order memory order = ilp.getRedeemOrder(orderId);
        assertTrue(order.executed);
    }

    function test_FillRedeemOrder_RevertInvalidOrder() public {
        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, 999));
        ilp.fillRedeemOrder(999);
    }

    function test_FillRedeemOrder_RevertOrderAlreadyExecuted() public {
        _setMaxDepositPerBlock(1_000e18);

        // Create and fill a redeem order
        vm.startPrank(user1);
        asset.approve(address(ilp), 100e18);
        uint256 shares = ilp.deposit(100e18, user1);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(shares);
        vm.stopPrank();

        vm.startPrank(orderFiller);
        asset.approve(address(ilp), assets);
        ilp.fillRedeemOrder(orderId);

        // Try to fill again
        vm.expectRevert(OrderAlreadyExecuted.selector);
        ilp.fillRedeemOrder(orderId);
        vm.stopPrank();
    }

    function test_FillRedeemOrder_RevertUnauthorized() public {
        _setMaxDepositPerBlock(1_000e18);

        // Create a redeem order
        vm.startPrank(user1);
        asset.approve(address(ilp), 100e18);
        uint256 shares = ilp.deposit(100e18, user1);
        (uint256 orderId,) = ilp.createRedeemOrder(shares);
        vm.stopPrank();

        // Try to fill as unauthorized user
        vm.prank(user2);
        vm.expectRevert();
        ilp.fillRedeemOrder(orderId);
    }

    // Rescue Tokens Tests
    function test_RescueTokens_Success() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 rescueAmount = 100e18;

        otherToken.mint(address(ilp), rescueAmount);

        uint256 balanceBefore = otherToken.balanceOf(user1);

        vm.prank(admin);
        ilp.rescueTokens(address(otherToken), user1, rescueAmount);

        assertEq(otherToken.balanceOf(user1), balanceBefore + rescueAmount);
        assertEq(otherToken.balanceOf(address(ilp)), 0);
    }

    function test_RescueTokens_RevertInvalidZeroAmount() public {
        ERC20Mock otherToken = new ERC20Mock();
        vm.prank(admin);
        vm.expectRevert(InvalidZeroAmount.selector);
        ilp.rescueTokens(address(otherToken), user1, 0);
    }

    function test_RescueTokens_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(asset)));
        ilp.rescueTokens(address(asset), user1, 100e18);
    }

    function test_RescueTokens_RevertUnauthorized() public {
        ERC20Mock otherToken = new ERC20Mock();
        vm.prank(user1);
        vm.expectRevert();
        ilp.rescueTokens(address(otherToken), user1, 100e18);
    }

    // Edge Cases and Complex Scenarios
    function test_MultipleDepositsInSameBlock() public {
        _setMaxDepositPerBlock(1_000e18);

        uint256 amount1 = 300e18;
        uint256 amount2 = 400e18;

        vm.startPrank(user1);
        asset.approve(address(ilp), amount1);
        ilp.deposit(amount1, user1);

        asset.approve(address(ilp), amount2);
        ilp.deposit(amount2, user1);
        vm.stopPrank();

        assertEq(ilp.depositedPerBlock(block.number), amount1 + amount2);
    }

    function test_MintLimitResetsNextBlock() public {
        uint256 maxDepositPerBlock = 500e18;
        _setMaxDepositPerBlock(maxDepositPerBlock);

        // Fill up current block limit
        vm.startPrank(user1);
        asset.approve(address(ilp), maxDepositPerBlock);
        ilp.deposit(maxDepositPerBlock, user1);

        assertEq(ilp.maxDeposit(user1), 0);

        // Move to next block
        vm.roll(block.number + 1);

        // Should be able to deposit again
        assertEq(ilp.maxDeposit(user1), maxDepositPerBlock);
        vm.stopPrank();
    }

    function test_YieldCalculationWithZeroPoolSize() public {
        // Set pool size to 0
        vm.prank(poolManager);
        ilp.updatePool(0, 0, 1e6);

        // Move forward in time
        vm.warp(block.timestamp + 1 days);

        // Total assets should still be 0
        assertEq(ilp.totalAssets(), 0);
    }

    function test_YieldCalculationWithZeroRate() public {
        uint256 poolSize = 10000e18;
        uint256 withdrawAllowance = 5000e18;
        uint256 dailyLinearYieldRatePpm = 0;

        // Set yield rate to 0
        vm.prank(poolManager);
        ilp.updatePool(poolSize, withdrawAllowance, dailyLinearYieldRatePpm);

        // Move forward in time
        vm.warp(block.timestamp + 1 days);

        // Total assets should equal pool size (no yield)
        assertEq(ilp.totalAssets(), poolSize);
    }
}
