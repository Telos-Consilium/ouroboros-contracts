// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

    uint256 public user1key;
    uint256 public user2key;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _deploy() internal virtual returns (address);

    function setUp() public virtual {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        limitManager = makeAddr("limitManager");
        redeemManager = makeAddr("redeemManager");
        orderFiller = makeAddr("orderFiller");

        Vm.Wallet memory user1Wallet = vm.createWallet("user1");
        user1 = user1Wallet.addr;
        user1key = user1Wallet.privateKey;

        Vm.Wallet memory user2Wallet = vm.createWallet("user2");
        user2 = user2Wallet.addr;
        user2key = user2Wallet.privateKey;

        // Deploy mock asset and mint balances
        asset = new USDCMock();
        asset.mint(user1, 10_000_000e6);
        asset.mint(user2, 10_000_000e6);
        asset.mint(orderFiller, 10_000_000e6);

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

    function _setBalances(address user, uint256 userDeposit, uint256 protoBalance) internal {
        if (userDeposit > 0) _deposit(user, userDeposit);
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

    function _packInitData(address _asset, address _admin, address _treasury) internal returns (bytes memory) {
        return abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(_asset),
            "Proto Token",
            "PROTO",
            _admin,
            _treasury,
            type(uint256).max, // maxDepositPerBlock
            type(uint256).max, // maxWithdrawPerBlock
            1 days // fillWindow
        );
    }

    function test_Initialize_Revert_ZeroAddress() public {
        address implementationAddress = _deploy();

        bytes memory initData_ZeroAsset = _packInitData(address(0), admin, treasury);
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(implementationAddress, initData_ZeroAsset);

        bytes memory initData_ZeroAdmin = _packInitData(address(asset), address(0), treasury);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new ERC1967Proxy(implementationAddress, initData_ZeroAdmin);

        bytes memory initData_ZeroTreasury = _packInitData(address(asset), admin, address(0));
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(implementationAddress, initData_ZeroTreasury);
    }

    function test_Initialize_Revert_AlreadyInitialized() public {
        vm.mockCallRevert(
            address(proto),
            _packInitData(address(asset), admin, treasury),
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
    }

    // Max Functions
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
    function _depositAndAssert(address caller, uint256 assets, address receiver) public {
        uint256 expectedTokens = proto.previewDeposit(assets);

        uint256 callerAssetsBefore = asset.balanceOf(caller);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Deposit(caller, receiver, assets, expectedTokens);
        uint256 mintedTokens = proto.deposit(assets, receiver);

        assertEq(mintedTokens, expectedTokens);

        assertEq(asset.balanceOf(caller), callerAssetsBefore - assets);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore + mintedTokens);
        assertEq(proto.totalSupply(), tokenSupplyBefore + mintedTokens);
    }

    function test_Deposit() public {
        address caller = user1;
        address receiver = user2;
        uint256 assets = 100e6;
        _depositAndAssert(caller, assets, receiver);
    }

    function test_Deposit_Zero() public {
        address caller = user1;
        address receiver = user2;
        uint256 assets = 0;
        _depositAndAssert(caller, assets, receiver);
    }

    function test_Deposit_Revert_ExceedsMaxDeposit() public {
        uint256 assets = 100e6;
        _setMaxDepositPerBlock(assets);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user2, assets + 1, assets));
        vm.prank(user1);
        proto.deposit(assets + 1, user2);
    }

    // Mint
    function _mintAndAssert(address caller, uint256 tokens, address receiver) public {
        uint256 expectedAssets = proto.previewMint(tokens);

        uint256 callerAssetsBefore = asset.balanceOf(caller);
        uint256 receiverTokensBefore = proto.balanceOf(receiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Deposit(caller, receiver, expectedAssets, tokens);
        uint256 depositedAssets = proto.mint(tokens, receiver);

        assertEq(depositedAssets, expectedAssets);

        assertEq(asset.balanceOf(caller), callerAssetsBefore - depositedAssets);
        assertEq(proto.balanceOf(receiver), receiverTokensBefore + tokens);
        assertEq(proto.totalSupply(), tokenSupplyBefore + tokens);
    }

    function test_Mint() public {
        address caller = user1;
        address receiver = user2;
        uint256 tokens = 100e18;
        _mintAndAssert(caller, tokens, receiver);
    }

    function test_Mint_Zero() public {
        address caller = user1;
        address receiver = user2;
        uint256 tokens = 0;
        _mintAndAssert(caller, tokens, receiver);
    }

    function test_Mint_Revert_ExceedsMaxMint() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setMaxDepositPerBlock(assets);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxMint.selector, user2, tokens + 1, tokens));
        proto.mint(tokens + 1, user2);
    }

    // Withdraw
    function _withdrawAndAssert(address caller, uint256 assets, address receiver, address owner) internal {
        uint256 expectedTokens = proto.previewWithdraw(assets);

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Withdraw(caller, receiver, owner, assets, expectedTokens);
        uint256 redeemedTokens = proto.withdraw(assets, receiver, owner);

        assertEq(redeemedTokens, expectedTokens);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - redeemedTokens);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(proto.totalSupply(), tokenSupplyBefore - redeemedTokens);
    }

    function test_Withdraw() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        _setBalances(user1, assets, assets);
        _withdrawAndAssert(caller, assets, receiver, owner);
    }

    function test_Withdraw_Zero() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 0;
        _withdrawAndAssert(caller, assets, receiver, owner);
    }

    function test_Withdraw_WithFee() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 fee = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemFee(fee);

        _setBalances(user1, assets + assets / 10, assets);
        _withdrawAndAssert(caller, assets, receiver, owner);
    }

    function test_Withdraw_Revert_ExceedsMaxWithdraw() public {
        uint256 assets = 100e6;
        _setMaxWithdrawPerBlock(assets);
        _setBalances(user1, assets, assets);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user1, assets + 1, assets));
        proto.withdraw(assets + 1, user2, user1);
    }

    // Redeem
    function _redeemAndAssert(address caller, uint256 tokens, address receiver, address owner) internal {
        uint256 expectedAssets = proto.previewRedeem(tokens);

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Withdraw(caller, receiver, owner, expectedAssets, tokens);
        uint256 withdrawnAssets = proto.redeem(tokens, receiver, owner);

        assertEq(withdrawnAssets, expectedAssets);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - tokens);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + withdrawnAssets);
        assertEq(proto.totalSupply(), tokenSupplyBefore - tokens);
    }

    function test_Redeem() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setBalances(user1, assets, assets);
        _redeemAndAssert(caller, tokens, receiver, owner);
    }

    function test_Redeem_Zero() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 tokens = 0;
        _redeemAndAssert(caller, tokens, receiver, owner);
    }

    function test_Redeem_WithFee() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        uint256 fee = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemFee(fee);

        _setBalances(user1, assets, assets);
        _redeemAndAssert(caller, tokens, receiver, owner);
    }

    function test_Redeem_Revert_ExceedsMaxRedeem() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setMaxWithdrawPerBlock(assets);
        _setBalances(user1, assets, assets);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user1, tokens + 1, tokens));
        proto.redeem(tokens + 1, user2, user1);
    }

    // Redeem Orders
    function _createRedeemOrderAndAssert(address caller, uint256 tokens, address receiver, address owner) internal {
        uint256 expectedAssets = proto.previewRedeemOrder(tokens);
        uint256 expectedOrderId = proto.orderCount();

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 contractTokensBefore = proto.balanceOf(address(proto));
        uint256 tokenSupplyBefore = proto.totalSupply();
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();

        vm.prank(caller);
        vm.expectEmit();
        emit CreatedRedeemOrder(caller, receiver, owner, expectedOrderId, expectedAssets, tokens);
        (uint256 orderId, uint256 assets) = proto.createRedeemOrder(tokens, receiver, owner);

        assertEq(assets, expectedAssets);
        assertEq(orderId, expectedOrderId);
        assertEq(proto.orderCount(), expectedOrderId + 1);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - tokens);
        assertEq(proto.balanceOf(address(proto)), contractTokensBefore + tokens);
        assertEq(proto.totalSupply(), tokenSupplyBefore);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore + tokens);

        Order memory order = proto.getRedeemOrder(orderId);
        assertEq(order.assets, expectedAssets);
        assertEq(order.tokens, tokens);
        assertEq(order.owner, owner);
        assertEq(order.receiver, receiver);
        assertEq(order.dueTime, block.timestamp + proto.fillWindow());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_CreateRedeemOrder() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);
    }

    function test_CreateRedeemOrder_Zero() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 tokens = 0;
        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);
    }

    function test_CreateRedeemOrder_WithFee() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        int256 fee = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(fee);

        _deposit(owner, assets);
        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);
    }

    function test_CreateRedeemOrder_WithIncentive() public {
        address caller = user1;
        address receiver = user2;
        address owner = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        int256 fee = -100_000; // -10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(fee);

        _deposit(owner, assets);
        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);
    }

    function test_CreateRedeemOrder_Revert_ExceedsMaxRedeemOrder() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setMaxWithdrawPerBlock(assets);
        _setBalances(user1, assets, assets);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user1, tokens + 1, tokens));
        proto.createRedeemOrder(tokens + 1, user2, user1);
    }

    function test_CreateRedeemOrder_Revert_ZeroReceiver() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setBalances(user1, assets, assets);
        vm.prank(user1);
        vm.expectRevert(InvalidZeroAddress.selector);
        proto.createRedeemOrder(tokens, address(0), user1);
    }

    function test_CreateRedeemOrder_Revert_InsufficientAllowance() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setBalances(user1, assets, assets);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, tokens));
        proto.createRedeemOrder(tokens, user2, user1);
    }

    function _fillRedeemOrderAndAssert(address caller, uint256 orderId) internal {
        Order memory order = proto.getRedeemOrder(orderId);

        uint256 receiverAssetsBefore = asset.balanceOf(order.receiver);
        uint256 tokensSupplyBefore = proto.totalSupply();
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();

        vm.prank(caller);
        vm.expectEmit();
        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, order.assets, order.tokens);
        vm.expectEmit();
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.tokens);
        proto.fillRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Filled));

        assertEq(asset.balanceOf(order.receiver), receiverAssetsBefore + order.assets);
        assertEq(proto.totalSupply(), tokensSupplyBefore - order.tokens);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore - order.tokens);
    }

    function test_FillRedeemOrder() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_WithFee() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        int256 fee = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(fee);

        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    // function test_FillRedeemOrder_WithIncentive() public {
    //     uint256 assets = 100e6;
    //     uint256 tokens = 100e18;
    //     int256 fee = -100_000; // -10%

    //     vm.prank(redeemManager);
    //     proto.setRedeemOrderFee(fee);

    //     _deposit(user1, assets);
    //     (uint256 orderId,) = _createRedeemOrder(user1, tokens);
    //     _fillRedeemOrderAndAssert(orderFiller, orderId);
    // }

    function test_FillRedeemOrder_PastDue() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        vm.warp(block.timestamp + proto.fillWindow());
        _fillRedeemOrderAndAssert(orderFiller, orderId);
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

        vm.warp(block.timestamp + proto.fillWindow());
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

    function _cancelRedeemOrderAndAssert(address caller, uint256 orderId) internal {
        Order memory order = proto.getRedeemOrder(orderId);

        uint256 ownerTokensBefore = proto.balanceOf(order.owner);
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();

        vm.prank(caller);
        vm.expectEmit();
        emit CancelledRedeemOrder(caller, orderId);
        proto.cancelRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Cancelled));

        assertEq(proto.balanceOf(order.owner), ownerTokensBefore + order.tokens);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore - order.tokens);
    }

    function test_CancelRedeemOrder_ByOwner() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);

        vm.prank(owner);
        proto.approve(controller, tokens);

        vm.prank(controller);
        (uint256 orderId,) = proto.createRedeemOrder(tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _cancelRedeemOrderAndAssert(owner, orderId);
    }

    function test_CancelRedeemOrder_ByController() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);

        vm.prank(owner);
        proto.approve(controller, tokens);

        vm.prank(controller);
        (uint256 orderId,) = proto.createRedeemOrder(tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _cancelRedeemOrderAndAssert(controller, orderId);
    }

    function test_CancelRedeemOrder_Revert_NotDue() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        proto.cancelRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_Revert_AlreadyCancelled() public {
        address caller = user1;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(caller, assets);
        (uint256 orderId,) = _createRedeemOrder(caller, tokens);

        vm.warp(block.timestamp + proto.fillWindow());

        vm.prank(caller);
        proto.cancelRedeemOrder(orderId);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.cancelRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_Revert_UnauthorizedManager() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderManager.selector, user2, user1, user1));
        proto.cancelRedeemOrder(orderId);
    }

    function test_Permit() public {
        address owner = user1;
        uint256 ownerPrivateKey = user1key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = proto.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", proto.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        assertEq(proto.allowance(owner, spender), 0);

        proto.permit(owner, spender, value, deadline, v, r, s);

        assertEq(proto.allowance(owner, spender), value);
        assertEq(proto.nonces(owner), nonce + 1);
    }

    function test_Permit_Revert_InvalidSigner() public {
        address owner = user1;
        uint256 invalidPrivateKey = user2key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = proto.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", proto.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(invalidPrivateKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, user2, user1));
        proto.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_Permit_Revert_ExpiredSignature() public {
        address owner = user1;
        uint256 ownerPrivateKey = user2key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = proto.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", proto.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        proto.permit(owner, spender, value, deadline, v, r, s);
    }

    // Fuzz
    function testFuzz_Deposit_Withdraw(address caller, address receiver, address owner, uint256 assets, uint256 fee)
        public
    {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));

        assets = bound(assets, 0, 1_000_000e6);
        fee = bound(fee, 0, 1_000_000); // 0% to 100%

        uint256 mintSize = proto.previewDeposit(assets);

        asset.mint(caller, assets);
        _setMaxDepositPerBlock(assets);
        _setMaxWithdrawPerBlock(assets);
        _setFees(fee, 0);

        vm.prank(admin);
        proto.setTreasury(address(proto));

        vm.prank(caller);
        asset.approve(address(proto), assets);

        _depositAndAssert(caller, assets, owner);

        vm.prank(owner);
        proto.approve(caller, mintSize);

        uint256 withdrawableAssets = proto.maxWithdraw(owner);
        _withdrawAndAssert(caller, withdrawableAssets, receiver, owner);
    }

    function testFuzz_Mint_Redeem(address caller, address receiver, address owner, uint256 tokens, uint256 fee)
        public
    {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));
        tokens = bound(tokens, 1e12, 1_000_000e18);
        fee = bound(fee, 0, 1_000_000); // 0% to 100%
        fee = 0;

        uint256 depositSize = proto.previewMint(tokens);

        asset.mint(caller, depositSize);
        _setMaxDepositPerBlock(depositSize);
        _setMaxWithdrawPerBlock(depositSize);
        _setFees(fee, 0);

        vm.prank(admin);
        proto.setTreasury(address(proto));

        vm.prank(caller);
        asset.approve(address(proto), depositSize);

        _mintAndAssert(caller, tokens, owner);

        vm.prank(owner);
        proto.approve(caller, tokens);

        uint256 redeemableTokens = proto.maxRedeem(owner);
        _redeemAndAssert(caller, redeemableTokens, receiver, owner);
    }

    // Admin Functions
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

    function test_RescueTokens_Token() public {
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

    function test_RescueToken_Revert_Asset() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidAssetRescue.selector, address(asset)));
        proto.rescueTokens(address(asset), admin, 100e6);
    }

    function test_RescueTokens_Revert_ExceededOutstandingBalance() public {
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

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        vm.expectEmit();
        emit UpdatedTreasury(treasury, newTreasury);
        proto.setTreasury(newTreasury);
        assertEq(proto.treasury(), newTreasury);
    }

    function test_SetTreasury_Revert_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(InvalidZeroAddress.selector);
        proto.setTreasury(address(0));
    }

    function test_SetTreasury_Revert_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.setTreasury(user1);
    }

    function test_SetRedeemFee() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedRedeemFee(0, 1_000_000);
        proto.setRedeemFee(1_000_000);
        assertEq(proto.redeemFeePpm(), 1_000_000);
    }

    function test_SetRedeemFee_Revert_ExceedsMaxFee() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        proto.setRedeemFee(1_000_001);
    }

    function test_SetRedeemFee_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setRedeemFee(100_000);
    }

    function test_SetRedeemOrderFee() public {
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

    function test_SetRedeemOrderFee_Revert_ExceedsMaxFee() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        proto.setRedeemOrderFee(1_000_001);
    }

    // function test_SetRedeemOrderFee_Revert_ExceedsMinFee() public {
    //     vm.prank(redeemManager);
    //     vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, -1_000_001, 1_000_000));
    //     proto.setRedeemOrderFee(-1_000_001);
    // }

    function test_SetRedeemOrderFee_Revert_NotRedeemManager() public {
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

    // Misc
    function test_DepositedPerBlock() public {
        _deposit(user1, 100e6);
        assertEq(proto.depositedPerBlock(block.number), 100e6);

        _deposit(user2, 200e6);
        assertEq(proto.depositedPerBlock(block.number), 300e6);
    }

    function test_WithdrawnPerBlock() public {
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

    function test_MintRedeem_AsTreasury() public {
        vm.prank(admin);
        proto.setTreasury(address(proto));

        _deposit(user1, 100e6);
        assertEq(asset.balanceOf(address(proto)), 100e6);

        _withdraw(user1, 100e6);
        assertEq(asset.balanceOf(address(proto)), 0);
    }
}
