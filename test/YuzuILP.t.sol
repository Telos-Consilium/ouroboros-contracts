// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
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

        // Deploy YuzuILP implementation
        YuzuILP implementation = new YuzuILP();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector, IERC20(address(asset)), "Yuzu ILP", "yzILP", admin, treasury, 1_000e18
        );

        // Deploy proxy and initialize
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        ilp = YuzuILP(address(proxy));

        // Set up roles
        vm.startPrank(admin);
        ilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        ilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        ilp.grantRole(POOL_MANAGER_ROLE, poolManager);
        ilp.setTreasury(treasury);
        vm.stopPrank();

        vm.startPrank(user1);
        ilp.approve(address(ilp), type(uint256).max);
        asset.approve(address(ilp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        ilp.approve(address(ilp), type(uint256).max);
        asset.approve(address(ilp), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(orderFiller);
        ilp.approve(address(ilp), type(uint256).max);
        asset.approve(address(ilp), type(uint256).max);
        vm.stopPrank();
    }

    function _updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm) internal {
        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawalAllowance, newDailyLinearYieldRatePpm);
    }

    function _setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) internal {
        vm.prank(limitManager);
        ilp.setMaxDepositPerBlock(newMaxDepositPerBlock);
    }

    // Initialization
    function test_Initialize() public {
        uint256 maxDepositPerBlock = 1_000e18;

        // Deploy new implementation
        YuzuILP newImplementation = new YuzuILP();

        // Prepare initialization data
        bytes memory newInitData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            IERC20(address(asset)),
            "Yuzu ILP",
            "yzILP",
            admin,
            treasury,
            maxDepositPerBlock
        );

        // Deploy new proxy
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImplementation), newInitData);
        YuzuILP newIlp = YuzuILP(address(newProxy));

        assertEq(address(newIlp.asset()), address(asset));
        assertEq(newIlp.name(), "Yuzu ILP");
        assertEq(newIlp.symbol(), "yzILP");
        assertEq(newIlp.treasury(), treasury);
        assertEq(newIlp.maxDepositPerBlock(), maxDepositPerBlock);
        assertTrue(newIlp.hasRole(ADMIN_ROLE, admin));
        assertTrue(newIlp.hasRole(newIlp.DEFAULT_ADMIN_ROLE(), admin));
    }

    // Admin Functions
    function test_SetMaxDepositPerBlock() public {
        uint256 newMaxDepositPerBlock = 2_000e18;

        vm.prank(limitManager);
        ilp.setMaxDepositPerBlock(newMaxDepositPerBlock);

        assertEq(ilp.maxDepositPerBlock(), newMaxDepositPerBlock);
    }

    function test_SetMaxDepositPerBlock_RevertOnlyLimitManager() public {
        vm.expectRevert();
        vm.prank(user1);
        ilp.setMaxDepositPerBlock(2_000e18);
    }

    function test_SetMaxDepositPerBlock_ZeroValue() public {
        uint256 newMaxDepositPerBlock = 0;

        vm.expectEmit();
        emit MaxDepositPerBlockUpdated(1_000e18, newMaxDepositPerBlock);
        vm.prank(limitManager);
        ilp.setMaxDepositPerBlock(newMaxDepositPerBlock);

        assertEq(ilp.maxDepositPerBlock(), newMaxDepositPerBlock);
        assertEq(ilp.maxDeposit(user1), 0);
    }

    function test_SetTreasury_RevertInvalidZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidZeroAddress.selector));
        vm.prank(admin);
        ilp.setTreasury(address(0));
    }

    function test_SetTreasury_RevertOnlyAdmin() public {
        address newTreasury = makeAddr("newTreasury");
        
        vm.expectRevert();
        vm.prank(user1);
        ilp.setTreasury(newTreasury);
    }

    function test_UpdatePool() public {
        uint256 newPoolSize = 2_000e18;
        uint256 newWithdrawAllowance = 1_000e18;
        uint256 newYieldRatePpm = 200_000; // 20% per day

        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawAllowance, newYieldRatePpm);

        assertEq(ilp.poolSize(), newPoolSize);
        assertEq(ilp.withdrawAllowance(), newWithdrawAllowance);
        assertEq(ilp.dailyLinearYieldRatePpm(), newYieldRatePpm);
        assertEq(ilp.lastPoolUpdateTimestamp(), block.timestamp);
    }

    function test_UpdatePool_RevertWithdrawalAllowanceExceedsPoolSize() public {
        vm.expectRevert(abi.encodeWithSelector(WithdrawalAllowanceExceedsPoolSize.selector, 2_000e18));
        vm.prank(poolManager);
        ilp.updatePool(1_000e18, 2_000e18, 0);
    }

    function test_UpdatePool_RevertOnlyPoolManager() public {
        vm.expectRevert();
        vm.prank(user1);
        ilp.updatePool(2_000e18, 1_000e18, 0);
    }

    function test_UpdatePool_ZeroPoolSize() public {
        uint256 newPoolSize = 0;
        uint256 newWithdrawAllowance = 0;
        uint256 newYieldRatePpm = 100_000; // 10% per day

        vm.expectEmit();
        emit PoolUpdated(newPoolSize, newWithdrawAllowance, newYieldRatePpm);
        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawAllowance, newYieldRatePpm);

        assertEq(ilp.poolSize(), newPoolSize);
        assertEq(ilp.withdrawAllowance(), newWithdrawAllowance);
        assertEq(ilp.dailyLinearYieldRatePpm(), newYieldRatePpm);
        assertEq(ilp.totalAssets(), 0);
    }

    function test_UpdatePool_ZeroWithdrawAllowance() public {
        uint256 newPoolSize = 1_000e18;
        uint256 newWithdrawAllowance = 0;
        uint256 newYieldRatePpm = 100_000; // 10% per day

        vm.expectEmit();
        emit PoolUpdated(newPoolSize, newWithdrawAllowance, newYieldRatePpm);
        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawAllowance, newYieldRatePpm);

        assertEq(ilp.poolSize(), newPoolSize);
        assertEq(ilp.withdrawAllowance(), newWithdrawAllowance);
        assertEq(ilp.dailyLinearYieldRatePpm(), newYieldRatePpm);
        assertEq(ilp.maxWithdraw(user1), 0);
        assertEq(ilp.maxRedeem(user1), 0);
    }

    function test_UpdatePool_ZeroYieldRate() public {
        uint256 newPoolSize = 1_000e18;
        uint256 newWithdrawAllowance = 500e18;
        uint256 newYieldRatePpm = 0;

        vm.expectEmit();
        emit PoolUpdated(newPoolSize, newWithdrawAllowance, newYieldRatePpm);
        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newWithdrawAllowance, newYieldRatePpm);

        assertEq(ilp.poolSize(), newPoolSize);
        assertEq(ilp.withdrawAllowance(), newWithdrawAllowance);
        assertEq(ilp.dailyLinearYieldRatePpm(), newYieldRatePpm);
        
        vm.warp(block.timestamp + 1 days);
        assertEq(ilp.totalAssets(), newPoolSize);
    }

    function test_UpdatePool_RevertInvalidYield() public {
        uint256 invalidYieldRate = 1e6 + 1; // Over 100% daily yield
        
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, invalidYieldRate));
        vm.prank(poolManager);
        ilp.updatePool(1_000e18, 500e18, invalidYieldRate);
    }

    function test_RescueTokens() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 rescueAmount = 100e18;
        uint256 balanceBefore = otherToken.balanceOf(user1);

        otherToken.mint(address(ilp), rescueAmount);

        vm.prank(admin);
        ilp.rescueTokens(address(otherToken), user1, rescueAmount);

        assertEq(otherToken.balanceOf(user1), balanceBefore + rescueAmount);
        assertEq(otherToken.balanceOf(address(ilp)), 0);
    }

    function test_RescueTokens_RevertInvalidToken() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(asset)));
        ilp.rescueTokens(address(asset), user1, 100e18);
    }

    function test_RescueTokens_RevertOnlyAdmin() public {
        ERC20Mock otherToken = new ERC20Mock();
        vm.expectRevert();
        vm.prank(user1);
        ilp.rescueTokens(address(otherToken), user1, 100e18);
    }

    function test_RescueTokens_ZeroAmount() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 rescueAmount = 0;
        uint256 balanceBefore = otherToken.balanceOf(user1);

        vm.prank(admin);
        ilp.rescueTokens(address(otherToken), user1, rescueAmount);

        assertEq(otherToken.balanceOf(user1), balanceBefore);
    }

    function test_RescueTokens_RevertZeroAddress() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 rescueAmount = 100e18;
        otherToken.mint(address(ilp), rescueAmount);

        vm.expectRevert();
        vm.prank(admin);
        ilp.rescueTokens(address(otherToken), address(0), rescueAmount);
    }

    // Deposit
    function test_Deposit() public {
        uint256 depositAmount = 100e6;
        uint256 expectedMint = 100e18;

        uint256 userSharesBefore = ilp.balanceOf(user1);
        uint256 treasuryBalanceBefore = asset.balanceOf(treasury);

        _setMaxDepositPerBlock(depositAmount);

        vm.prank(user1);
        uint256 mintedShares = ilp.deposit(depositAmount, user1);

        assertEq(mintedShares, expectedMint);

        assertEq(ilp.balanceOf(user1), userSharesBefore + mintedShares);
        assertEq(asset.balanceOf(treasury), treasuryBalanceBefore + depositAmount);

        assertEq(ilp.poolSize(), depositAmount);
        assertEq(ilp.totalAssets(), depositAmount);
        assertEq(ilp.totalSupply(), mintedShares);

        assertEq(ilp.depositedPerBlock(block.number), depositAmount);

        assertEq(ilp.withdrawAllowance(), depositAmount);
        assertEq(ilp.maxDeposit(user1), 0);
        assertEq(ilp.maxMint(user1), 0);
        assertEq(ilp.maxRedeem(user1), mintedShares);
        assertEq(ilp.maxWithdraw(user1), depositAmount);
    }

    function test_Deposit_UpdatesStateWithYieldDiscount() public {
        uint256 depositAmount = 100e18;
        uint256 yieldRatePpm = 250_000; // 25% daily yield
        
        _setMaxDepositPerBlock(depositAmount);

        vm.prank(user1);
        ilp.deposit(depositAmount, user1);

        _updatePool(depositAmount, 0, yieldRatePpm);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 days);

        uint256 poolSizeBefore = ilp.poolSize();
        uint256 totalAssetsBefore = ilp.totalAssets();

        vm.prank(user2);
        ilp.deposit(depositAmount, user2);

        uint256 poolSizeAfter = ilp.poolSize();
        assertLt(poolSizeAfter - poolSizeBefore, depositAmount);
        assertGt(poolSizeAfter, poolSizeBefore);

        uint256 expectedPoolSizeIncrease = 80e18;
        assertEq(poolSizeAfter, poolSizeBefore + expectedPoolSizeIncrease);

        uint256 totalAssetsAfter = ilp.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + depositAmount);
    }

    function test_MaxDeposit_RespectsMintLimit() public {
        _setMaxDepositPerBlock(1_000e18);

        uint256 maxDeposit = ilp.maxDeposit(user1);
        vm.prank(user1);
        ilp.deposit(maxDeposit, user1);

        assertEq(ilp.maxDeposit(user1), 0);
        assertEq(ilp.maxMint(user1), 0);
    }

    function test_Deposit_RevertExceedsMintLimit() public {
        uint256 maxDepositsPerBlock = 1_000e18;
        _setMaxDepositPerBlock(maxDepositsPerBlock);

        vm.expectRevert();
        vm.prank(user1);
        ilp.deposit(maxDepositsPerBlock + 1, user1);
    }

    // Total Assets
    function test_TotalAssets() public {
        assertEq(ilp.totalAssets(), ilp.poolSize());
    }

    function test_TotalAssets_WithYield() public {
        uint256 poolSize = 1_000e18;
        uint256 withdrawAllowance = 0;
        uint256 yieldRatePpm = 100_000; // 10%

        _updatePool(poolSize, withdrawAllowance, yieldRatePpm);

        // Move forward 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 expectedYield = 100e18;
        uint256 expectedTotal = poolSize + expectedYield;

        assertEq(ilp.totalAssets(), expectedTotal);
    }

    function test_TotalAssets_PartialDay() public {
        uint256 poolSize = 1_000e18;
        uint256 withdrawAllowance = 0;
        uint256 yieldRatePpm = 100_000; // 10%
        uint256 elapsedTime = 12 hours; // Half a day

        _updatePool(poolSize, withdrawAllowance, yieldRatePpm);

        // Move forward 12 hours (half day)
        vm.warp(block.timestamp + elapsedTime);

        uint256 expectedYield = 50e18;
        uint256 expectedTotal = poolSize + expectedYield;
        assertEq(ilp.totalAssets(), expectedTotal);
    }

    // Max Withdraw/Redeem
    function test_MaxWithdraw_RespectsBalance() public {
        uint256 depositAmount = 100e18;

        _setMaxDepositPerBlock(depositAmount);

        vm.prank(user1);
        ilp.deposit(depositAmount, user1);

        _updatePool(2 * depositAmount, 2 * depositAmount, 0);

        uint256 userShares = ilp.balanceOf(user1);
        uint256 maxWithdrawFromShares = ilp.convertToAssets(userShares);
        uint256 maxWithdraw = ilp.maxWithdraw(user1);
        assertEq(maxWithdraw, maxWithdrawFromShares);
    }

    function test_MaxRedeem_RespectsAllowance() public {
        uint256 depositAmount = 100e18;

        _setMaxDepositPerBlock(depositAmount);

        vm.prank(user1);
        ilp.deposit(depositAmount, user1);

        uint256 withdrawAllowance = 50e18;
        _updatePool(depositAmount, withdrawAllowance, 0);

        uint256 maxRedeemFromAllowance = ilp.convertToShares(withdrawAllowance);
        uint256 maxRedeem = ilp.maxRedeem(user1);
        assertEq(maxRedeem, maxRedeemFromAllowance);
    }

    // Withdraw/Redeem Not Supported
    function test_Withdraw_RevertWithdrawNotSupported() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        ilp.withdraw(100e18, user1, user1);
    }

    function test_Redeem_RevertRedeemNotSupported() public {
        vm.expectRevert(RedeemNotSupported.selector);
        ilp.redeem(100e18, user1, user1);
    }

    // Redeem Order Creation
    function test_CreateRedeemOrder() public {
        _setMaxDepositPerBlock(1_000e18);

        // Deposit
        uint256 depositSize = 50e18;
        vm.prank(user1);
        uint256 mintedShares = ilp.deposit(depositSize, user1);

        // Create redeem order
        vm.expectEmit();
        emit RedeemOrderCreated(0, user1, depositSize, mintedShares);
        vm.prank(user1);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(mintedShares);

        assertEq(depositSize, assets);
        assertEq(ilp.totalAssets() / assets, ilp.totalSupply() / mintedShares);
        assertEq(orderId, 0);
        assertEq(ilp.redeemOrderCount(), 1);

        Order memory order = ilp.getRedeemOrder(orderId);
        assertEq(order.assets, assets);
        assertEq(order.shares, mintedShares);
        assertEq(order.owner, user1);
        assertFalse(order.executed);

        assertEq(ilp.balanceOf(user1), 0);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.withdrawAllowance(), 0);
    }

    function test_CreateRedeemOrder_RevertInvalidZeroShares() public {
        vm.expectRevert(InvalidZeroShares.selector);
        vm.prank(user1);
        ilp.createRedeemOrder(0);
    }

    function test_CreateRedeemOrder_RevertMaxRedeemExceeded() public {
        _setMaxDepositPerBlock(1_000e18);

        vm.prank(user1);
        ilp.deposit(100e18, user1);

        uint256 maxRedeem = ilp.maxRedeem(user1);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemExceeded.selector, maxRedeem + 1, maxRedeem));
        vm.prank(user1);
        ilp.createRedeemOrder(maxRedeem + 1);
    }

    // Redeem Order Filling
    function test_FillRedeemOrder() public {
        uint256 depositAmount = 100e18;
        _setMaxDepositPerBlock(depositAmount);

        // Create redeem order
        vm.startPrank(user1);
        uint256 mintedShares = ilp.deposit(depositAmount, user1);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(mintedShares);
        vm.stopPrank();

        uint256 userBalanceBefore = asset.balanceOf(user1);
        uint256 fillerBalanceBefore = asset.balanceOf(orderFiller);

        // Fill the order
        vm.expectEmit();
        emit RedeemOrderFilled(orderId, user1, orderFiller, assets, mintedShares);
        vm.prank(orderFiller);
        ilp.fillRedeemOrder(orderId);

        // Check balances
        assertEq(asset.balanceOf(user1), userBalanceBefore + assets);
        assertEq(asset.balanceOf(orderFiller), fillerBalanceBefore - assets);

        // Check order is marked as executed
        Order memory order = ilp.getRedeemOrder(orderId);
        assertTrue(order.executed);
    }

    function test_FillRedeemOrder_RevertInvalidOrder() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidOrder.selector, 999));
        vm.prank(orderFiller);
        ilp.fillRedeemOrder(999);
    }

    function test_FillRedeemOrder_RevertOrderAlreadyExecuted() public {
        _setMaxDepositPerBlock(1_000e18);

        // Create and fill a redeem order
        vm.startPrank(user1);
        uint256 mintedShares = ilp.deposit(100e18, user1);
        (uint256 orderId, uint256 assets) = ilp.createRedeemOrder(mintedShares);
        vm.stopPrank();

        vm.startPrank(orderFiller);
        ilp.fillRedeemOrder(orderId);
        // Try to fill again
        vm.expectRevert(OrderAlreadyExecuted.selector);
        ilp.fillRedeemOrder(orderId);
        vm.stopPrank();
    }

    function test_FillRedeemOrder_RevertOnlyOrderFiller() public {
        _setMaxDepositPerBlock(1_000e18);

        // Create a redeem order
        vm.startPrank(user1);
        uint256 mintedShares = ilp.deposit(100e18, user1);
        (uint256 orderId,) = ilp.createRedeemOrder(mintedShares);
        vm.stopPrank();

        // Try to fill as unauthorized user
        vm.expectRevert();
        vm.prank(user2);
        ilp.fillRedeemOrder(orderId);
    }

    // Integration
    function test_MultipleDepositsInSameBlock() public {
        _setMaxDepositPerBlock(1_000e18);

        uint256 deposit1 = 300e18;
        uint256 deposit2 = 400e18;

        vm.startPrank(user1);
        ilp.deposit(deposit1, user1);
        ilp.deposit(deposit2, user1);
        vm.stopPrank();

        assertEq(ilp.depositedPerBlock(block.number), deposit1 + deposit2);
    }

    function test_MintLimitResetsNextBlock() public {
        uint256 maxDepositPerBlock = 500e18;
        _setMaxDepositPerBlock(maxDepositPerBlock);

        // Fill up current block limit
        vm.prank(user1);
        ilp.deposit(maxDepositPerBlock, user1);

        assertEq(ilp.maxDeposit(user1), 0);

        // Move to next block
        vm.roll(block.number + 1);

        // Should be able to deposit again
        assertEq(ilp.maxDeposit(user1), maxDepositPerBlock);
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
        uint256 yieldRatePpm = 0;

        // Set yield rate to 0
        vm.prank(poolManager);
        ilp.updatePool(poolSize, withdrawAllowance, yieldRatePpm);

        // Move forward in time
        vm.warp(block.timestamp + 1 days);

        // Total assets should equal pool size (no yield)
        assertEq(ilp.totalAssets(), poolSize);
    }
}
