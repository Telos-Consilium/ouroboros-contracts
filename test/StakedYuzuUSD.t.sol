// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

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
    error OwnableInvalidOwner(address owner);

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
        yzusd.mint(user1, 10_000_000e18);
        yzusd.mint(user2, 10_000_000e18);

        // Deploy implementation and proxy-initialize
        StakedYuzuUSD implementation = new StakedYuzuUSD();
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            owner,
            type(uint256).max,
            type(uint256).max,
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
        assertEq(styz.maxDepositPerBlock(), type(uint256).max);
        assertEq(styz.maxWithdrawPerBlock(), type(uint256).max);
        assertEq(styz.redeemDelay(), 1 days);
    }

    function _packInitData(address _asset, address _owner) internal returns (bytes memory) {
        return abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(_asset),
            "Staked Yuzu USD",
            "st-yzUSD",
            _owner,
            type(uint256).max,
            type(uint256).max,
            1 days
        );
    }

    function test_Initialize_Revert_ZeroAddress() public {
        StakedYuzuUSD implementation = new StakedYuzuUSD();

        bytes memory initData_ZeroAsset = _packInitData(address(0), owner);
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData_ZeroAsset);

        bytes memory initData_ZeroOwner = _packInitData(address(yzusd), address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(implementation), initData_ZeroOwner);
    }

    function test_Initialize_Revert_AlreadyInitialized() public {
        vm.mockCallRevert(
            address(styz),
            _packInitData(address(yzusd), owner),
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
    }

    // Redeem Initiation
    function _initiateRedeemAndAssert(address caller, uint256 shares, address receiver, address _owner) internal {
        uint256 expectedAssets = styz.previewRedeem(shares);
        uint256 expectedOrderId = styz.orderCount();

        uint256 ownerSharesBefore = styz.balanceOf(_owner);
        uint256 shareSupplyBefore = styz.totalSupply();
        uint256 withdrawnPerBlockBefore = styz.withdrawnPerBlock(block.number);
        uint256 pendingOrderValueBefore = styz.totalPendingOrderValue();

        uint256 callerAllowanceBefore = styz.allowance(_owner, caller);

        vm.prank(caller);
        vm.expectEmit();
        emit InitiatedRedeem(caller, receiver, _owner, expectedOrderId, expectedAssets, shares);
        (uint256 orderId, uint256 _assets) = styz.initiateRedeem(shares, receiver, _owner);

        assertEq(_assets, expectedAssets);
        assertEq(orderId, expectedOrderId);
        assertEq(styz.orderCount(), expectedOrderId + 1);

        assertEq(styz.balanceOf(_owner), ownerSharesBefore - shares);
        assertEq(styz.totalSupply(), shareSupplyBefore - shares);
        assertEq(styz.withdrawnPerBlock(block.number), withdrawnPerBlockBefore + expectedAssets);
        assertEq(styz.totalPendingOrderValue(), pendingOrderValueBefore + expectedAssets);

        if (caller != _owner) {
            assertEq(styz.allowance(_owner, caller), callerAllowanceBefore - shares);
        }

        Order memory order = styz.getRedeemOrder(orderId);
        assertEq(order.assets, expectedAssets);
        assertEq(order.shares, shares);
        assertEq(order.owner, _owner);
        assertEq(order.receiver, receiver);
        assertEq(order.dueTime, block.timestamp + styz.redeemDelay());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_InitiateRedeem() public {
        address caller = user1;
        address receiver = user1;
        address _owner = user1;
        uint256 mintedShares = _deposit(_owner, 100e18);
        _initiateRedeemAndAssert(caller, mintedShares, receiver, _owner);
    }

    function test_InitiateRedeem_Zero() public {
        address caller = user1;
        address receiver = user1;
        address _owner = user1;
        uint256 shares = 0;
        _initiateRedeemAndAssert(caller, shares, receiver, _owner);
    }

    function test_InitiateRedeem_WithFee() public {
        address caller = user1;
        address receiver = user1;
        address _owner = user1;
        uint256 fee = 100_000; // 10%

        vm.prank(owner);
        styz.setRedeemFee(fee);

        uint256 mintedShares = _deposit(_owner, 100e18);
        _initiateRedeemAndAssert(caller, mintedShares, receiver, _owner);
    }

    function test_InitiateRedeem_Revert_ExceedsMaxRedeem() public {
        uint256 mintedShares = _deposit(user1, 100e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626ExceededMaxRedeem.selector, user1, mintedShares + 1, mintedShares)
        );
        styz.initiateRedeem(mintedShares + 1, user1, user1);
    }

    function test_InitiateRedeem_Revert_ZeroReceiver() public {
        uint256 mintedShares = _deposit(user1, 100e18);
        vm.prank(user1);
        vm.expectRevert(InvalidZeroAddress.selector);
        styz.initiateRedeem(mintedShares, address(0), user1);
    }

    function test_InitiateRedeem_Revert_InsufficientAllowance() public {
        uint256 mintedShares = _deposit(user1, 100e18);
        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, mintedShares)
        );
        styz.initiateRedeem(mintedShares, user2, user1);
    }

    // Redeem Finalization
    function _finalizeRedeemAndAssert(address caller, uint256 orderId) internal {
        Order memory order = styz.getRedeemOrder(orderId);

        uint256 receiverAssetsBefore = yzusd.balanceOf(order.receiver);
        uint256 contractAssetsBefore = yzusd.balanceOf(address(styz));
        uint256 withdrawnPerBlockBefore = styz.withdrawnPerBlock(block.number);
        uint256 pendingOrderValueBefore = styz.totalPendingOrderValue();

        vm.prank(caller);
        vm.expectEmit();
        emit FinalizedRedeem(caller, order.receiver, order.owner, orderId, order.assets, order.shares);
        vm.expectEmit();
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.shares);
        styz.finalizeRedeem(orderId);

        Order memory orderAfter = styz.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Executed));

        assertEq(yzusd.balanceOf(order.receiver), receiverAssetsBefore + order.assets);
        assertEq(yzusd.balanceOf(address(styz)), contractAssetsBefore - order.assets);
        assertEq(styz.withdrawnPerBlock(block.number), withdrawnPerBlockBefore);
        assertEq(styz.totalPendingOrderValue(), pendingOrderValueBefore - order.assets);
    }

    function test_FinalizeRedeem() public {
        address caller = user1;
        address _owner = user1;
        uint256 mintedShares = _deposit(_owner, 100e18);
        vm.prank(_owner);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, _owner, _owner);
        vm.warp(block.timestamp + styz.redeemDelay());
        _finalizeRedeemAndAssert(caller, orderId);
    }

    function test_FinalizeRedeem_Revert_InvalidOrder() public {
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, 999));
        styz.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_Revert_NotDue() public {
        vm.startPrank(user1);
        uint256 mintedShares = styz.deposit(200e18, user1);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, user1, user1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_Revert_NotPending() public {
        vm.startPrank(user1);
        uint256 mintedShares = styz.deposit(200e18, user1);
        (uint256 orderId,) = styz.initiateRedeem(mintedShares, user1, user1);
        vm.stopPrank();

        vm.warp(block.timestamp + styz.redeemDelay());
        styz.finalizeRedeem(orderId);

        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    // Fuzz
    function testFuzz_InitiateRedeem_FinalizeRedeem(
        address caller,
        address receiver,
        address _owner,
        uint256 shares,
        uint256 fee
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && _owner != address(0));
        vm.assume(caller != address(styz) && receiver != address(styz) && _owner != address(styz));
        shares = bound(shares, 1e12, 1_000_000e18);
        fee = bound(fee, 0, 1_000_000); // 0% to 100%

        uint256 depositSize = styz.previewMint(shares);

        yzusd.mint(_owner, depositSize);
        _setMaxDepositPerBlock(depositSize);
        _setMaxWithdrawPerBlock(depositSize);

        vm.startPrank(_owner);
        yzusd.approve(address(styz), depositSize);
        styz.deposit(depositSize, _owner);
        styz.approve(caller, shares);
        vm.stopPrank();

        _initiateRedeemAndAssert(caller, shares, receiver, _owner);
        vm.warp(block.timestamp + styz.redeemDelay());
        _finalizeRedeemAndAssert(caller, styz.orderCount() - 1);
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

    function test_RescueTokens_Share() public {
        uint256 mintedShares = _deposit(user1, 100e18);

        vm.prank(user1);
        styz.transfer(address(styz), mintedShares);

        uint256 balanceBefore = styz.balanceOf(user1);

        vm.prank(owner);
        styz.rescueTokens(address(styz), user1, mintedShares);

        assertEq(styz.balanceOf(user1), balanceBefore + mintedShares);
        assertEq(styz.balanceOf(address(styz)), 0);
    }

    function test_RescueToken_Revert_Asset() public {
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

    function test_Setters() public {
        vm.startPrank(owner);
        // Set Max Deposit
        vm.expectEmit();
        emit UpdatedMaxDepositPerBlock(type(uint256).max, 200e18);
        styz.setMaxDepositPerBlock(200e18);
        assertEq(styz.maxDepositPerBlock(), 200e18);
        // Set Max Withdraw
        vm.expectEmit();
        emit UpdatedMaxWithdrawPerBlock(type(uint256).max, 200e18);
        styz.setMaxWithdrawPerBlock(200e18);
        assertEq(styz.maxWithdrawPerBlock(), 200e18);
        // Set Redeem Fee
        vm.expectEmit();
        emit UpdatedRedeemFee(0, 1_000_000);
        styz.setRedeemFee(1_000_000);
        assertEq(styz.redeemFeePpm(), 1_000_000);
        // Set Redeem Delay
        vm.expectEmit();
        emit UpdatedRedeemDelay(1 days, 2 days);
        styz.setRedeemDelay(2 days);
        assertEq(styz.redeemDelay(), 2 days);
        vm.stopPrank();
    }

    function test_Setters_Revert_NotOwner() public {
        vm.startPrank(user1);
        // Set Max Deposit
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setMaxDepositPerBlock(200e18);
        // Set Max Withdraw
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setMaxWithdrawPerBlock(200e18);
        // Set Redeem Fee
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setRedeemFee(100_000);
        // Set Redeem Delay
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user1));
        styz.setRedeemDelay(2 days);
        vm.stopPrank();
    }

    function test_SetRedeemFee_Revert_ExceedsMaxFee() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        styz.setRedeemFee(1_000_001);
    }

    function test_SetRedeemDelay_Revert_TooHigh() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(RedeemDelayTooHigh.selector, uint256(type(uint32).max) + 1, type(uint32).max)
        );
        styz.setRedeemDelay(uint256(type(uint32).max) + 1);
    }

    // ERC-4626 Override
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

    function test_PreviewWithdraw_WithFee() public {
        _deposit(user1, 200e18);
        vm.prank(owner);
        styz.setRedeemFee(100_000); // 10%
        assertEq(styz.previewWithdraw(100e18), 110e18);
    }

    function test_PreviewRedeem_WithFee() public {
        uint256 mintedShares = _deposit(user1, 100e18);
        vm.prank(owner);
        styz.setRedeemFee(100_000); // 10%
        assertEq(styz.previewRedeem(mintedShares), uint256(100e18) * 10 / 11);
    }

    function test_Withdraw_Revert() public {
        vm.expectRevert(WithdrawNotSupported.selector);
        styz.withdraw(100e18, user1, user1);
    }

    function test_Redeem_Revert() public {
        vm.expectRevert(RedeemNotSupported.selector);
        styz.redeem(100e18, user1, user1);
    }

    // Misc
    function test_TotalAssets_WithCommitment() public {
        uint256 initialAssets = styz.totalAssets();

        uint256 depositAmount = 100e18;
        vm.prank(user1);
        uint256 mintedShares = styz.deposit(depositAmount, user1);
        assertEq(styz.totalAssets(), initialAssets + depositAmount);

        vm.prank(user1);
        styz.initiateRedeem(mintedShares, user1, user1);

        assertEq(styz.totalAssets(), initialAssets);
    }

    function test_PreviewRedeem_WithAccruedAssets() public {
        uint256 depositAmount = 100e18;
        uint256 mintedShares = _deposit(user1, depositAmount);

        // Double the value of the shares
        yzusd.mint(address(styz), depositAmount);

        assertEq(styz.maxRedeem(user1), mintedShares);
        assertEq(styz.previewRedeem(1e18), 2e18 - 1);
    }

    function test_MaxDeposit_MaxMint_AcrossBlocks() public {
        _setMaxDepositPerBlock(100e18);
        _deposit(user1, 50e18);

        assertEq(styz.maxDeposit(user1), 50e18);
        assertEq(styz.maxMint(user1), 50e18);

        vm.roll(block.number + 1);

        assertEq(styz.maxDeposit(user1), 100e18);
        assertEq(styz.maxMint(user1), 100e18);
    }

    function test_MaxWithdraw_MaxRedeem_AcrossBlocks() public {
        _setMaxWithdrawPerBlock(100e18);
        _deposit(user1, 100e18);
        _deposit(user2, 100e18);

        vm.prank(user1);
        styz.initiateRedeem(50e18, user2, user1);

        // Limited by balance
        assertEq(styz.maxWithdraw(user1), 50e18);
        assertEq(styz.maxRedeem(user1), 50e18);
        // Limited by max
        assertEq(styz.maxWithdraw(user2), 50e18);
        assertEq(styz.maxRedeem(user2), 50e18);

        vm.roll(block.number + 1);

        // Limited by balance
        assertEq(styz.maxWithdraw(user1), 50e18);
        assertEq(styz.maxRedeem(user1), 50e18);
        // Limited by max
        assertEq(styz.maxWithdraw(user2), 100e18);
        assertEq(styz.maxRedeem(user2), 100e18);
    }

    function test_DepositedPerBlock() public {
        _deposit(user1, 100e18);
        assertEq(styz.depositedPerBlock(block.number), 100e18);
        _deposit(user2, 200e18);
        assertEq(styz.depositedPerBlock(block.number), 300e18);

        vm.roll(block.number + 1);
        assertEq(styz.depositedPerBlock(block.number), 0);
    }

    function test_WithdrawnPerBlock() public {
        _deposit(user1, 300e18);

        vm.prank(user1);
        (, uint256 assetsWithdrawn1) = styz.initiateRedeem(100e18, user1, user1);
        assertEq(styz.withdrawnPerBlock(block.number), assetsWithdrawn1);

        vm.prank(user1);
        (, uint256 assetsWithdrawn2) = styz.initiateRedeem(200e18, user1, user1);
        assertEq(styz.withdrawnPerBlock(block.number), assetsWithdrawn1 + assetsWithdrawn2);

        vm.roll(block.number + 1);
        assertEq(styz.withdrawnPerBlock(block.number), 0);
    }
}
