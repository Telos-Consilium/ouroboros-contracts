// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuProtoDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";

import {YuzuProto} from "../src/proto/YuzuProto.sol";
import {YuzuILP} from "../src/YuzuILP.sol";

contract USDCMock is ERC20Mock {
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

abstract contract YuzuProtoTest is Test, IYuzuIssuerDefinitions, IYuzuOrderBookDefinitions, IYuzuProtoDefinitions {
    YuzuProto public proto;
    USDCMock public asset;

    address public admin;
    address public treasury;
    address public limitManager;
    address public redeemManager;
    address public orderFiller;
    address public user1;
    address public user2;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    function _deploy() internal virtual returns (address);

    function setUp() public virtual {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        limitManager = makeAddr("limitManager");
        redeemManager = makeAddr("redeemManager");
        orderFiller = makeAddr("orderFiller");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock asset and mint balances
        asset = new USDCMock();
        asset.mint(user1, 1_000_000e6);
        asset.mint(user2, 1_000_000e6);
        asset.mint(orderFiller, 1_000_000e6);

        // Deploy implementation and proxy-initialize
        address implementationAddress = _deploy();
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(asset),
            "Proto Token",
            "PROTO",
            admin,
            treasury,
            type(uint256).max, // maxDepositPerBlock
            type(uint256).max, // maxWithdrawPerBlock
            1 days // fillWindow
        );
        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proto = YuzuProto(address(proxy));

        // Grant roles from admin
        vm.startPrank(admin);
        proto.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        proto.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        proto.grantRole(ORDER_FILLER_ROLE, orderFiller);
        vm.stopPrank();

        // Approvals for deposits/orders
        vm.prank(user1);
        asset.approve(address(proto), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(proto), type(uint256).max);
        vm.prank(orderFiller);
        asset.approve(address(proto), type(uint256).max);
    }

    // Helpers
    function _deposit(address from, uint256 amount) internal returns (uint256 tokens) {
        vm.prank(from);
        return proto.deposit(amount, from);
    }

    function _withdraw(address from, uint256 amount) internal returns (uint256 withdrawnAssets) {
        vm.prank(from);
        return proto.withdraw(amount, from, from);
    }

    function _createRedeemOrder(address from, uint256 amount) internal returns (uint256 orderId, uint256 assets) {
        vm.prank(from);
        return proto.createRedeemOrder(amount, from, from);
    }

    function _setMaxDepositPerBlock(uint256 maxDepositPerBlock) internal {
        vm.prank(limitManager);
        proto.setMaxDepositPerBlock(maxDepositPerBlock);
    }

    function _setMaxWithdrawPerBlock(uint256 maxWithdrawPerBlock) internal {
        vm.prank(limitManager);
        proto.setMaxWithdrawPerBlock(maxWithdrawPerBlock);
    }

    function _setFees(uint256 redeemFeePpm, int256 orderFeePpm) internal {
        vm.startPrank(redeemManager);
        if (redeemFeePpm > 0) proto.setRedeemFee(redeemFeePpm);
        if (orderFeePpm != 0) proto.setRedeemOrderFee(orderFeePpm);
        vm.stopPrank();
    }

    function _setBalances(uint256 userDeposit, uint256 protoBalance) internal {
        if (userDeposit > 0) _deposit(user1, userDeposit);
        if (protoBalance > 0) asset.mint(address(proto), protoBalance);
    }

    // Initialization
    function test_Initialize() public {
        assertEq(proto.asset(), address(asset));
        assertEq(proto.name(), "Proto Token");
        assertEq(proto.symbol(), "PROTO");
        assertEq(proto.treasury(), treasury);
        assertEq(proto.maxDepositPerBlock(), type(uint256).max);
        assertEq(proto.maxWithdrawPerBlock(), type(uint256).max);
        assertEq(proto.fillWindow(), 1 days);

        assertEq(proto.getRoleAdmin(ADMIN_ROLE), proto.DEFAULT_ADMIN_ROLE());
        assertEq(proto.getRoleAdmin(LIMIT_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(proto.getRoleAdmin(REDEEM_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(proto.getRoleAdmin(ORDER_FILLER_ROLE), ADMIN_ROLE);

        assertTrue(proto.hasRole(proto.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(proto.hasRole(ADMIN_ROLE, admin));
    }

    // Max functions
    function test_MaxDeposit_MaxMint() public {
        _setMaxDepositPerBlock(0);

        assertEq(proto.maxDeposit(user1), 0);
        assertEq(proto.maxMint(user1), 0);

        _setMaxDepositPerBlock(100e6);

        assertEq(proto.maxDeposit(user1), 100e6);
        assertEq(proto.maxMint(user1), 100e18);
    }

    function test_MaxWithdraw_MaxRedeem() public {
        vm.prank(redeemManager);
        proto.setRedeemFee(100_000); // 10%

        _setMaxWithdrawPerBlock(0);

        // Limited by max, balance, and buffer
        assertEq(proto.maxWithdraw(user1), 0);
        assertEq(proto.maxRedeem(user1), 0);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 0);

        _setMaxWithdrawPerBlock(100e6);

        // Limited by balance and buffer
        assertEq(proto.maxWithdraw(user1), 0);
        assertEq(proto.maxRedeem(user1), 0);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 0);

        asset.mint(address(proto), 200e6);

        // Limited by balance
        assertEq(proto.maxWithdraw(user1), 0);
        assertEq(proto.maxRedeem(user1), 0);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 0);

        _deposit(user1, 300e6);

        // Limited by max
        assertEq(proto.maxWithdraw(user1), 100e6);
        assertEq(proto.maxRedeem(user1), 110e18);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 300e18);

        _setMaxWithdrawPerBlock(500e6);

        // Limited by buffer
        assertEq(proto.maxWithdraw(user1), 200e6);
        assertEq(proto.maxRedeem(user1), 220e18);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 300e18);

        asset.mint(address(proto), 400e6);

        // Limited by balance
        assertEq(proto.maxWithdraw(user1), 272_727272);
        assertEq(proto.maxRedeem(user1), 300e18);
        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 300e18);
    }

    // Deposit
    function _depositAndAssert(uint256 depositAmount, uint256 expectedTokens) public {
        assertEq(proto.previewDeposit(depositAmount), expectedTokens);

        address sender = user1;
        address receiver = user2;

        uint256 senderAssetsBefore = asset.balanceOf(sender);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 treasuryAssetsBefore = asset.balanceOf(treasury);

        uint256 senderTokensBefore = proto.balanceOf(sender);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);

        uint256 supplyBefore = proto.totalSupply();
        uint256 depositedPerBlockBefore = proto.depositedPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Deposit(sender, receiver, depositAmount, expectedTokens);
        uint256 mintedTokens = proto.deposit(depositAmount, receiver);

        assertEq(mintedTokens, expectedTokens);

        assertEq(asset.balanceOf(sender), senderAssetsBefore - depositAmount);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore);
        assertEq(asset.balanceOf(treasury), treasuryAssetsBefore + depositAmount);

        assertEq(proto.balanceOf(sender), senderTokensBefore);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore + expectedTokens);

        assertEq(proto.totalSupply(), supplyBefore + mintedTokens);
        assertEq(proto.depositedPerBlock(block.number), depositedPerBlockBefore + depositAmount);
    }

    function test_Deposit() public {
        _depositAndAssert(100e6, 100e18);
    }

    function test_Deposit_Zero() public {
        _depositAndAssert(0, 0);
    }

    function test_Deposit_Revert_ExceedsMaxDeposit() public {
        _setMaxDepositPerBlock(100e6);

        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user2, 100e6 + 1, 100e6));
        vm.prank(user1);
        proto.deposit(100e6 + 1, user2);
    }

    // Mint
    function _mintAndAssert(uint256 mintAmount, uint256 expectedAssets) public {
        assertEq(proto.previewMint(mintAmount), expectedAssets);

        address sender = user1;
        address receiver = user2;

        uint256 senderAssetsBefore = asset.balanceOf(sender);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 treasuryAssetsBefore = asset.balanceOf(treasury);

        uint256 senderTokensBefore = proto.balanceOf(sender);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);

        uint256 supplyBefore = proto.totalSupply();
        uint256 depositedPerBlockBefore = proto.depositedPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Deposit(sender, receiver, expectedAssets, mintAmount);
        uint256 depositedAssets = proto.deposit(expectedAssets, receiver);

        assertEq(depositedAssets, mintAmount);

        assertEq(asset.balanceOf(sender), senderAssetsBefore - expectedAssets);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore);
        assertEq(asset.balanceOf(treasury), treasuryAssetsBefore + expectedAssets);

        assertEq(proto.balanceOf(sender), senderTokensBefore);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore + mintAmount);

        assertEq(proto.totalSupply(), supplyBefore + mintAmount);
        assertEq(proto.depositedPerBlock(block.number), depositedPerBlockBefore + expectedAssets);
    }

    function test_Mint() public {
        _mintAndAssert(100e18, 100e6);
    }

    function test_Mint_Zero() public {
        _mintAndAssert(0, 0);
    }

    function test_Mint_Revert_ExceedsMaxMint() public {
        _setMaxDepositPerBlock(100e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxMint.selector, user2, 100e18 + 1, 100e18));
        proto.mint(100e18 + 1, user2);
    }

    // Withdraw
    function _withdrawAndAssert(uint256 withdrawAmount, uint256 expectedTokens) internal {
        assertEq(proto.previewWithdraw(withdrawAmount), expectedTokens);

        address sender = user1;
        address owner = user1;
        address receiver = user2;

        uint256 ownerAssetsBefore = asset.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 protoAssetsBefore = asset.balanceOf(address(proto));

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);

        uint256 supplyBefore = proto.totalSupply();
        uint256 withdrawnPerBlockBefore = proto.withdrawnPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Withdraw(sender, receiver, owner, withdrawAmount, expectedTokens);
        uint256 redeemedTokens = proto.withdraw(withdrawAmount, receiver, owner);

        assertEq(redeemedTokens, expectedTokens);

        assertEq(asset.balanceOf(owner), ownerAssetsBefore);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + withdrawAmount);
        assertEq(asset.balanceOf(address(proto)), protoAssetsBefore - withdrawAmount);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - redeemedTokens);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore);

        assertEq(proto.totalSupply(), supplyBefore - redeemedTokens);
        assertEq(proto.withdrawnPerBlock(block.number), withdrawnPerBlockBefore + withdrawAmount);
    }

    function test_Withdraw() public {
        _setBalances(100e6, 100e6);
        _withdrawAndAssert(100e6, 100e18);
    }

    function test_Withdraw_Zero() public {
        _withdrawAndAssert(0, 0);
    }

    function test_Withdraw_WithFee() public {
        vm.prank(redeemManager);
        proto.setRedeemFee(100_000); // 10%
        _setBalances(110e6, 100e6);
        _withdrawAndAssert(100e6, 110e18);
    }

    function test_Withdraw_Revert_ExceedsMaxWithdraw() public {
        _setMaxWithdrawPerBlock(100e6);

        _setBalances(200e6, 200e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user1, 100e6 + 1, 100e6));
        proto.withdraw(100e6 + 1, user2, user1);
    }

    // Redeem
    function _redeemAndAssert(uint256 redeemAmount, uint256 expectedAssets) internal {
        assertEq(proto.previewRedeem(redeemAmount), expectedAssets);

        address sender = user1;
        address owner = user1;
        address receiver = user2;

        uint256 ownerAssetsBefore = asset.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 protoAssetsBefore = asset.balanceOf(address(proto));

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);

        uint256 supplyBefore = proto.totalSupply();
        uint256 withdrawnPerBlockBefore = proto.withdrawnPerBlock(block.number);

        vm.prank(sender);
        vm.expectEmit();
        emit Withdraw(sender, receiver, owner, expectedAssets, redeemAmount);
        uint256 withdrawnAssets = proto.redeem(redeemAmount, receiver, owner);

        assertEq(withdrawnAssets, expectedAssets);

        assertEq(asset.balanceOf(owner), ownerAssetsBefore);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + expectedAssets);
        assertEq(asset.balanceOf(address(proto)), protoAssetsBefore - expectedAssets);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - redeemAmount);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore);

        assertEq(proto.totalSupply(), supplyBefore - redeemAmount);
        assertEq(proto.withdrawnPerBlock(block.number), withdrawnPerBlockBefore + expectedAssets);
    }

    function test_Redeem() public {
        _setBalances(100e6, 100e6);
        _redeemAndAssert(100e18, 100e6);
    }

    function test_Redeem_Zero() public {
        _redeemAndAssert(0, 0);
    }

    function test_Redeem_WithFee() public {
        vm.prank(redeemManager);
        proto.setRedeemFee(100_000); // 10%
        _setBalances(100e6, 100e6);
        _redeemAndAssert(100e18, 90_909090);
    }

    function test_Redeem_Revert_ExceedsMaxRedeem() public {
        _setMaxWithdrawPerBlock(100e6);

        _setBalances(200e6, 200e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user1, 100e18 + 1, 100e18));
        proto.redeem(100e18 + 1, user2, user1);
    }

    // Redeem Orders
    function _createRedeemOrderAndAssert(uint256 redeemAmount, uint256 expectedAssets) internal {
        assertEq(proto.previewRedeemOrder(redeemAmount), expectedAssets);

        address sender = user1;
        address owner = user1;
        address receiver = user2;

        uint256 ownerAssetsBefore = asset.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 protoAssetsBefore = asset.balanceOf(address(proto));

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);
        uint256 protoTokensBefore = proto.balanceOf(address(proto));

        uint256 supplyBefore = proto.totalSupply();
        uint256 withdrawnPerBlockBefore = proto.withdrawnPerBlock(block.number);

        uint256 orderCountBefore = proto.orderCount();

        vm.prank(sender);
        vm.expectEmit();
        emit CreatedRedeemOrder(sender, receiver, owner, orderCountBefore, expectedAssets, redeemAmount);
        (uint256 orderId, uint256 orderAssets) = proto.createRedeemOrder(redeemAmount, receiver, owner);

        assertEq(orderId, orderCountBefore);
        assertEq(orderAssets, expectedAssets);

        Order memory order = proto.getRedeemOrder(orderId);
        assertEq(order.assets, expectedAssets);
        assertEq(order.tokens, redeemAmount);
        assertEq(order.owner, owner);
        assertEq(order.receiver, receiver);
        assertEq(order.dueTime, block.timestamp + proto.fillWindow());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));

        assertEq(asset.balanceOf(owner), ownerAssetsBefore);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore);
        assertEq(asset.balanceOf(address(proto)), protoAssetsBefore);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - redeemAmount);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore);
        assertEq(proto.balanceOf(address(proto)), protoTokensBefore + redeemAmount);

        assertEq(proto.totalSupply(), supplyBefore);
        assertEq(proto.withdrawnPerBlock(block.number), withdrawnPerBlockBefore);
    }

    function test_CreateRedeemOrder() public {
        _deposit(user1, 100e6);
        _createRedeemOrderAndAssert(100e18, 100e6);
    }

    function test_CreateRedeemOrder_Zero() public {
        _createRedeemOrderAndAssert(0, 0);
    }

    function test_CreateRedeemOrder_WithFee() public {
        vm.prank(redeemManager);
        proto.setRedeemOrderFee(100_000); // 10%
        _deposit(user1, 100e6);
        _createRedeemOrderAndAssert(100e18, 90_909090);
    }

    function test_CreateRedeemOrder_WithIncentive() public {
        vm.prank(redeemManager);
        proto.setRedeemOrderFee(-100_000); // -10%
        _deposit(user1, 100e6);
        _createRedeemOrderAndAssert(100e18, 110e6);
    }

    function test_CreateRedeemOrder_ExceedsMaxRedeemOrder() public {
        _setMaxWithdrawPerBlock(100e6);
        _deposit(user1, 101e6);
        _createRedeemOrderAndAssert(101e18, 101e6);
    }

    function _fillRedeemOrderAndAssert(uint256 orderId) internal {
        address filler = orderFiller;

        Order memory orderBefore = proto.getRedeemOrder(orderId);

        uint256 ownerAssetsBefore = asset.balanceOf(orderBefore.owner);
        uint256 receiverAssetsBefore = asset.balanceOf(orderBefore.receiver);
        uint256 protoAssetsBefore = asset.balanceOf(address(proto));
        uint256 fillerAssetsBefore = asset.balanceOf(filler);

        uint256 ownerTokensBefore = proto.balanceOf(orderBefore.owner);
        uint256 receiverTokensBefore = proto.balanceOf(orderBefore.receiver);
        uint256 protoTokensBefore = proto.balanceOf(address(proto));
        uint256 fillerTokensBefore = proto.balanceOf(filler);

        uint256 supplyBefore = proto.totalSupply();
        uint256 withdrawnPerBlockBefore = proto.withdrawnPerBlock(block.number);

        vm.prank(orderFiller);
        vm.expectEmit();
        emit FilledRedeemOrder(
            orderFiller, orderBefore.receiver, orderBefore.owner, orderId, orderBefore.assets, orderBefore.tokens
        );
        vm.expectEmit();
        emit Withdraw(orderFiller, orderBefore.receiver, orderBefore.owner, orderBefore.assets, orderBefore.tokens);
        proto.fillRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(orderAfter.assets, orderBefore.assets);
        assertEq(orderAfter.tokens, orderBefore.tokens);
        assertEq(orderAfter.owner, orderBefore.owner);
        assertEq(orderAfter.receiver, orderBefore.receiver);
        assertEq(orderAfter.dueTime, orderBefore.dueTime);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Filled));

        // if (orderBefore.owner != orderBefore.receiver) {
        //     assertEq(asset.balanceOf(orderAfter.owner), ownerAssetsBefore);
        // }

        assertEq(asset.balanceOf(orderAfter.receiver), receiverAssetsBefore + orderAfter.assets);
        assertEq(asset.balanceOf(address(proto)), protoAssetsBefore);
        assertEq(asset.balanceOf(filler), fillerAssetsBefore - orderAfter.assets);

        assertEq(proto.balanceOf(orderAfter.owner), ownerTokensBefore);
        assertEq(proto.balanceOf(orderAfter.receiver), receiverTokensBefore);
        assertEq(proto.balanceOf(address(proto)), protoTokensBefore - orderAfter.tokens);
        assertEq(proto.balanceOf(filler), fillerTokensBefore);

        assertEq(proto.totalSupply(), supplyBefore - orderAfter.tokens);
        assertEq(proto.withdrawnPerBlock(block.number), withdrawnPerBlockBefore);
    }

    function test_FillRedeemOrder() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrderAndAssert(orderId);
    }

    function test_FillRedeemOrder_WithFee() public {
        vm.prank(redeemManager);
        proto.setRedeemOrderFee(100_000); // 10%
        _deposit(user1, 200e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrderAndAssert(orderId);
    }

    function test_FillRedeemOrder_WithIncentive() public {
        vm.prank(redeemManager);
        proto.setRedeemOrderFee(-100_000); // -10%
        _deposit(user1, 200e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrderAndAssert(orderId);
    }

    function test_FillRedeemOrder_PastDue() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        vm.warp(block.timestamp + 1 days);
        _fillRedeemOrderAndAssert(orderId);
    }

    function test_FillRedeemOrder_Revert_AlreadyFilled() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.prank(orderFiller);
        proto.fillRedeemOrder(orderId);

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.fillRedeemOrder(orderId);
    }

    function test_FillRedeemOrder_Revert_Cancelled() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.warp(block.timestamp + 1 days);

        vm.prank(user1);
        proto.cancelRedeemOrder(orderId);

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.fillRedeemOrder(orderId);
    }

    function test_FillRedeemOrder_Revert_NotFiller() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, ORDER_FILLER_ROLE)
        );
        proto.fillRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.warp(block.timestamp + 1 days);

        Order memory orderBefore = proto.getRedeemOrder(orderId);

        uint256 ownerAssetsBefore = asset.balanceOf(orderBefore.owner);
        uint256 receiverAssetsBefore = asset.balanceOf(orderBefore.receiver);
        uint256 protoAssetsBefore = asset.balanceOf(address(proto));

        uint256 ownerTokensBefore = proto.balanceOf(orderBefore.owner);
        uint256 receiverTokensBefore = proto.balanceOf(orderBefore.receiver);
        uint256 protoTokensBefore = proto.balanceOf(address(proto));

        uint256 supplyBefore = proto.totalSupply();
        uint256 withdrawnPerBlockBefore = proto.withdrawnPerBlock(block.number);

        vm.prank(orderBefore.owner);
        vm.expectEmit();
        emit CancelledRedeemOrder(orderId);
        proto.cancelRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(orderAfter.assets, orderBefore.assets);
        assertEq(orderAfter.tokens, orderBefore.tokens);
        assertEq(orderAfter.owner, orderBefore.owner);
        assertEq(orderAfter.receiver, orderBefore.receiver);
        assertEq(orderAfter.dueTime, orderBefore.dueTime);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Cancelled));

        assertEq(asset.balanceOf(orderAfter.owner), ownerAssetsBefore);
        assertEq(asset.balanceOf(orderAfter.receiver), receiverAssetsBefore);
        assertEq(asset.balanceOf(address(proto)), protoAssetsBefore);

        // if (orderAfter.owner != orderAfter.receiver) {
        //     assertEq(proto.balanceOf(orderAfter.receiver), receiverTokensBefore);
        // }

        assertEq(proto.balanceOf(orderAfter.owner), ownerTokensBefore + orderAfter.tokens);
        assertEq(proto.balanceOf(address(proto)), protoTokensBefore - orderAfter.tokens);

        assertEq(proto.totalSupply(), supplyBefore);
        assertEq(proto.withdrawnPerBlock(block.number), withdrawnPerBlockBefore);
    }

    function test_CancelRedeemOrder_Revert_NotDue() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        proto.cancelRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_Revert_NotOwner() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(NotOrderOwner.selector, user2, user1));
        proto.cancelRedeemOrder(orderId);
    }

    // Admin functions
    function test_WithdrawCollateral() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        proto.withdrawCollateral(50e6, admin);
        assertEq(asset.balanceOf(admin), 50e6);
        assertEq(asset.balanceOf(address(proto)), 50e6);
    }

    function test_WithdrawCollateral_Revert_ExceedsLiquidityBuffer() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExceededLiquidityBuffer.selector, 101e6, 100e6));
        proto.withdrawCollateral(101e6, admin);
    }

    function test_WithdrawCollateral_Revert_NotAdmin() public {
        asset.mint(address(proto), 100e6);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.withdrawCollateral(100e6, user1);
    }

    function test_RescueTokens() public {
        ERC20Mock otherAsset = new ERC20Mock();
        otherAsset.mint(address(proto), 100e6);
        uint256 balanceBefore = otherAsset.balanceOf(user1);

        vm.prank(admin);
        proto.rescueTokens(address(otherAsset), user1, 50e6);

        assertEq(otherAsset.balanceOf(user1), balanceBefore + 50e6);
        assertEq(otherAsset.balanceOf(address(proto)), 50e6);
    }

    function test_RescueTokens_UnderlyingToken() public {
        _deposit(user1, 100e6);

        vm.prank(user1);
        proto.transfer(address(proto), 50e18);

        vm.prank(user1);
        proto.createRedeemOrder(50e18, user1, user1);

        uint256 balanceBefore = proto.balanceOf(user1);

        vm.prank(admin);
        proto.rescueTokens(address(proto), user1, 50e18);

        assertEq(proto.balanceOf(user1), balanceBefore + 50e18);
        assertEq(proto.balanceOf(address(proto)), 50e18);
    }

    function test_RescueToken_Revert_UnderlyingAsset() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidAssetRescue.selector, address(asset)));
        proto.rescueTokens(address(asset), admin, 100e6);
    }

    function test_RescueTokens_UnderlyingToken_Revert_ExceededOutstandingBalance() public {
        _deposit(user1, 100e6);

        vm.prank(user1);
        proto.transfer(address(proto), 50e18);

        vm.prank(user1);
        proto.createRedeemOrder(50e18, user1, user1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ExceededOutstandingBalance.selector, 50e18 + 1, 50e18));
        proto.rescueTokens(address(proto), admin, 50e18 + 1);
    }

    function test_RescueTokens_Revert_NotAdmin() public {
        ERC20Mock otherAsset = new ERC20Mock();
        otherAsset.mint(address(proto), 100e6);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.rescueTokens(address(otherAsset), user2, 50e6);
    }

    // Configuration functions
    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        vm.expectEmit();
        emit UpdatedTreasury(treasury, newTreasury);
        proto.setTreasury(newTreasury);
        assertEq(proto.treasury(), newTreasury);
    }

    function test_SetTreasury_Revert_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.setTreasury(user1);
    }

    function test_setRedeemFee() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedRedeemFee(0, 1_000_000);
        proto.setRedeemFee(1_000_000);
        assertEq(proto.redeemFeePpm(), 1_000_000);
    }

    function test_setRedeemFee_Revert_ExceedsMax() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        proto.setRedeemFee(1_000_001);
    }

    function test_setRedeemFee_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setRedeemFee(100_000);
    }

    function test_setRedeemOrderFee() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedRedeemOrderFee(0, 1_000_000);
        proto.setRedeemOrderFee(1_000_000);
        assertEq(proto.redeemOrderFeePpm(), 1_000_000);

        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedRedeemOrderFee(1_000_000, -1_000_000);
        proto.setRedeemOrderFee(-1_000_000);
        assertEq(proto.redeemOrderFeePpm(), -1_000_000);
    }

    function test_setRedeemOrderFee_Revert_ExceedsMaxFee() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        proto.setRedeemOrderFee(1_000_001);
    }

    // function test_setRedeemOrderFee_Revert_ExceedsMinFee() public {
    //     vm.prank(redeemManager);
    //     vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, -1_000_001, 1_000_000));
    //     proto.setRedeemOrderFee(-1_000_001);
    // }

    function test_setRedeemOrderFee_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setRedeemOrderFee(100_000);
    }

    function test_SetMaxDepositPerBlock() public {
        vm.prank(limitManager);
        vm.expectEmit();
        emit UpdatedMaxDepositPerBlock(type(uint256).max, 200e6);
        proto.setMaxDepositPerBlock(200e6);
        assertEq(proto.maxDepositPerBlock(), 200e6);
    }

    function test_SetMaxDepositPerBlock_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        proto.setMaxDepositPerBlock(200e6);
    }

    function test_SetMaxWithdrawPerBlock() public {
        vm.prank(limitManager);
        vm.expectEmit();
        emit UpdatedMaxWithdrawPerBlock(type(uint256).max, 200e6);
        proto.setMaxWithdrawPerBlock(200e6);
        assertEq(proto.maxWithdrawPerBlock(), 200e6);
    }

    function test_SetMaxWithdrawPerBlock_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        proto.setMaxWithdrawPerBlock(200e6);
    }

    function test_SetFillWindow() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedFillWindow(1 days, 2 days);
        proto.setFillWindow(2 days);
        assertEq(proto.fillWindow(), 2 days);
    }

    function test_SetFillWindow_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setFillWindow(2 days);
    }

    // Miscellaneous
    function test_depositedPerBlock() public {
        _deposit(user1, 100e6);
        assertEq(proto.depositedPerBlock(block.number), 100e6);

        _deposit(user2, 200e6);
        assertEq(proto.depositedPerBlock(block.number), 300e6);
    }

    function test_withdrawnPerBlock() public {
        _deposit(user1, 300e6);
        asset.mint(address(proto), 300e6);

        vm.prank(user1);
        proto.withdraw(100e6, user2, user1);
        assertEq(proto.withdrawnPerBlock(block.number), 100e6);

        vm.prank(user1);
        proto.withdraw(200e6, user2, user1);
        assertEq(proto.withdrawnPerBlock(block.number), 300e6);
    }

    function test_MaxDeposit_MaxMint_AcrossBlocks() public {
        _setMaxDepositPerBlock(100e6);

        asset.mint(address(proto), 200e6);
        _deposit(user1, 50e6);

        assertEq(proto.maxDeposit(user1), 50e6);
        assertEq(proto.maxMint(user1), 50e18);

        vm.roll(block.number + 1);

        assertEq(proto.maxDeposit(user1), 100e6);
        assertEq(proto.maxMint(user1), 100e18);
    }

    function test_MaxWithdraw_MaxRedeem_AcrossBlocks() public {
        _setMaxWithdrawPerBlock(100e6);

        asset.mint(address(proto), 200e6);
        _deposit(user1, 300e6);

        vm.prank(user1);
        proto.withdraw(50e6, user2, user1);

        assertEq(proto.maxWithdraw(user1), 50e6);
        assertEq(proto.maxRedeem(user1), 50e18);
        assertEq(proto.maxRedeemOrder(user1), 250e18);

        vm.roll(block.number + 1);

        assertEq(proto.maxWithdraw(user1), 100e6);
        assertEq(proto.maxRedeem(user1), 100e18);
        assertEq(proto.maxRedeemOrder(user1), 250e18);
    }

    function test_Withdraw_DifferentSender() public {
        _setBalances(100e6, 100e6);
        vm.prank(user1);
        proto.approve(user2, 100e18);
        vm.prank(user2);
        proto.withdraw(100e6, user2, user1);
    }

    function test_Withdraw_DifferentSender_Revert_InsufficientAllowance() public {
        _setBalances(100e6, 100e6);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, 100e18));
        proto.withdraw(100e6, user2, user1);
    }

    function test_Redeem_DifferentSender() public {
        _setBalances(100e6, 100e6);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, 100e18));
        proto.redeem(100e18, user2, user1);
    }

    function test_MintRedeem_AsTreasury() public {
        vm.prank(admin);
        proto.setTreasury(address(proto));

        _deposit(user1, 100e6);
        assertEq(asset.balanceOf(address(proto)), 100e6);

        _withdraw(user1, 100e6);
        assertEq(asset.balanceOf(address(proto)), 0);
    }
}
