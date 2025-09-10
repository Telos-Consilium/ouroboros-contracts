// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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
    address public feeReceiver;
    address public limitManager;
    address public redeemManager;
    address public orderFiller;
    address public user1;
    address public user2;

    uint256 public user1key;
    uint256 public user2key;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function _deploy() internal virtual returns (address);

    function setUp() public virtual {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        feeReceiver = makeAddr("feeReceiver");
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
            feeReceiver,
            type(uint256).max, // supplyCap
            1 days, // fillWindow
            0 // minRedeemOrder
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
        _approveAssets(user1, address(proto), type(uint256).max);
        _approveAssets(user2, address(proto), type(uint256).max);
        _approveAssets(orderFiller, address(proto), type(uint256).max);
    }

    // Helpers
    function _approveAssets(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        asset.approve(spender, amount);
    }

    function _approveTokens(address owner, address spender, uint256 tokens) internal {
        vm.prank(owner);
        proto.approve(spender, tokens);
    }

    function _deposit(address caller, uint256 assets, address receiver) internal returns (uint256 tokens) {
        vm.prank(caller);
        return proto.deposit(assets, receiver);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 tokens) {
        return _deposit(user, assets, user);
    }

    function _withdraw(address caller, uint256 assets, address receiver, address owner)
        internal
        returns (uint256 withdrawnAssets)
    {
        vm.prank(caller);
        return proto.withdraw(assets, receiver, owner);
    }

    function _withdraw(address user, uint256 assets) internal returns (uint256 withdrawnAssets) {
        vm.prank(user);
        return proto.withdraw(assets, user, user);
    }

    function _createRedeemOrder(address caller, uint256 tokens, address receiver, address owner)
        internal
        returns (uint256 orderId)
    {
        vm.prank(caller);
        return proto.createRedeemOrder(tokens, receiver, owner);
    }

    function _createRedeemOrder(address user, uint256 tokens) internal returns (uint256 orderId) {
        return _createRedeemOrder(user, tokens, user, user);
    }

    function _cancelRedeemOrder(address user, uint256 orderId) internal {
        vm.prank(user);
        proto.cancelRedeemOrder(orderId);
    }

    function _fillRedeemOrder(uint256 orderId) internal {
        vm.prank(orderFiller);
        proto.fillRedeemOrder(orderId);
    }

    function _finalizeRedeemOrder(uint256 orderId) internal {
        vm.prank(user1);
        proto.finalizeRedeemOrder(orderId);
    }

    function _setSupplyCap(uint256 cap) internal {
        vm.prank(limitManager);
        proto.setSupplyCap(cap);
    }

    function _setFees(uint256 redeemFeePpm, uint256 orderFeePpm) internal {
        vm.startPrank(redeemManager);
        if (redeemFeePpm > 0) proto.setRedeemFee(redeemFeePpm);
        if (orderFeePpm != 0) proto.setRedeemOrderFee(orderFeePpm);
        vm.stopPrank();
    }

    function _depositAndMint(address user, uint256 userDeposit, uint256 protoBalance) internal {
        if (userDeposit > 0) _deposit(user, userDeposit);
        if (protoBalance > 0) asset.mint(address(proto), protoBalance);
    }

    // Initialization
    function _packInitData(address _asset, address _admin, address _treasury, address _feeReceiver)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(_asset),
            "Proto Token",
            "PROTO",
            _admin,
            _treasury,
            _feeReceiver,
            type(uint256).max, // supplyCap
            1 days, // fillWindow
            0 // minRedeemOrder
        );
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

    // Withdraw
    function _withdrawAndAssert(address caller, uint256 assets, address receiver, address owner) internal {
        uint256 expectedTokens = proto.previewWithdraw(assets);
        uint256 expectedFee = Math.ceilDiv(assets * proto.redeemFeePpm(), 1_000_000);

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 feeReceiverAssetsBefore = asset.balanceOf(feeReceiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Withdraw(caller, receiver, owner, assets, expectedTokens);
        uint256 redeemedTokens = proto.withdraw(assets, receiver, owner);

        assertEq(redeemedTokens, expectedTokens);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - redeemedTokens);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(asset.balanceOf(feeReceiver), feeReceiverAssetsBefore + expectedFee);
        assertEq(proto.totalSupply(), tokenSupplyBefore - redeemedTokens);
    }

    // Redeem
    function _redeemAndAssert(address caller, uint256 tokens, address receiver, address owner) internal {
        uint256 expectedAssets = proto.previewRedeem(tokens);
        uint256 expectedFee = proto.convertToAssets(tokens) - expectedAssets;

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 feeReceiverAssetsBefore = asset.balanceOf(feeReceiver);
        uint256 tokenSupplyBefore = proto.totalSupply();

        vm.prank(caller);
        vm.expectEmit();
        emit Withdraw(caller, receiver, owner, expectedAssets, tokens);
        uint256 withdrawnAssets = proto.redeem(tokens, receiver, owner);

        assertEq(withdrawnAssets, expectedAssets);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - tokens);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore + withdrawnAssets);
        assertEq(asset.balanceOf(feeReceiver), feeReceiverAssetsBefore + expectedFee);
        assertEq(proto.totalSupply(), tokenSupplyBefore - tokens);
    }

    // Redeem Orders
    function _createRedeemOrderAndAssert(address caller, uint256 tokens, address receiver, address owner) internal {
        uint256 expectedOrderId = proto.orderCount();

        uint256 ownerTokensBefore = proto.balanceOf(owner);
        uint256 contractTokensBefore = proto.balanceOf(address(proto));
        uint256 tokenSupplyBefore = proto.totalSupply();
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();
        uint256 unfinalizedOrderValue = proto.totalUnfinalizedOrderValue();

        vm.prank(caller);
        vm.expectEmit();
        emit CreatedRedeemOrder(caller, receiver, owner, expectedOrderId, tokens);
        uint256 orderId = proto.createRedeemOrder(tokens, receiver, owner);

        assertEq(orderId, expectedOrderId);
        assertEq(proto.orderCount(), expectedOrderId + 1);

        assertEq(proto.balanceOf(owner), ownerTokensBefore - tokens);
        assertEq(proto.balanceOf(address(proto)), contractTokensBefore + tokens);
        assertEq(proto.totalSupply(), tokenSupplyBefore);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore + tokens);
        assertEq(proto.totalUnfinalizedOrderValue(), unfinalizedOrderValue);

        Order memory order = proto.getRedeemOrder(orderId);
        assertEq(order.assets, 0);
        assertEq(order.tokens, tokens);
        assertEq(order.owner, owner);
        assertEq(order.receiver, receiver);
        assertEq(order.dueTime, block.timestamp + proto.fillWindow());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function _fillRedeemOrderAndAssert(address caller, uint256 orderId) internal {
        Order memory order = proto.getRedeemOrder(orderId);

        uint256 expectedAssets = proto.previewRedeemOrder(order.tokens);
        uint256 expectedFee = proto.convertToAssets(order.tokens) - expectedAssets;

        uint256 contractAssetsBefore = asset.balanceOf(address(proto));
        uint256 tokensSupplyBefore = proto.totalSupply();
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();
        uint256 unfinalizedOrderValue = proto.totalUnfinalizedOrderValue();

        vm.prank(caller);
        vm.expectEmit();
        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, expectedAssets, order.tokens, expectedFee);
        proto.fillRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Filled));

        assertEq(asset.balanceOf(address(proto)), contractAssetsBefore + expectedAssets);
        assertEq(proto.totalSupply(), tokensSupplyBefore - order.tokens);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore - order.tokens);
        assertEq(proto.totalUnfinalizedOrderValue(), unfinalizedOrderValue + expectedAssets);
    }

    function _finalizeRedeemOrderAndAssert(address caller, uint256 orderId) internal {
        Order memory order = proto.getRedeemOrder(orderId);

        uint256 contractAssetsBefore = asset.balanceOf(address(proto));
        uint256 receiverAssetsBefore = asset.balanceOf(order.receiver);
        uint256 pendingOrderSizeBefore = proto.totalPendingOrderSize();
        uint256 unfinalizedOrderValue = proto.totalUnfinalizedOrderValue();

        vm.prank(caller);
        vm.expectEmit();
        emit FinalizedRedeemOrder(caller, order.receiver, order.owner, orderId, order.assets, order.tokens);
        vm.expectEmit();
        emit Withdraw(caller, order.receiver, order.owner, order.assets, order.tokens);
        proto.finalizeRedeemOrder(orderId);

        Order memory orderAfter = proto.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Finalized));

        assertEq(asset.balanceOf(address(proto)), contractAssetsBefore - order.assets);
        assertEq(asset.balanceOf(order.receiver), receiverAssetsBefore + order.assets);
        assertEq(proto.totalPendingOrderSize(), pendingOrderSizeBefore);
        assertEq(proto.totalUnfinalizedOrderValue(), unfinalizedOrderValue - order.assets);
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
}

abstract contract YuzuProtoTest_Common is YuzuProtoTest {
    // Initialization
    function test_Initialize() public {
        assertEq(proto.asset(), address(asset));
        assertEq(proto.name(), "Proto Token");
        assertEq(proto.symbol(), "PROTO");
        assertEq(proto.treasury(), treasury);
        assertEq(proto.cap(), type(uint256).max);
        assertEq(proto.fillWindow(), 1 days);

        assertEq(proto.getRoleAdmin(ADMIN_ROLE), proto.DEFAULT_ADMIN_ROLE());
        assertEq(proto.getRoleAdmin(LIMIT_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(proto.getRoleAdmin(REDEEM_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(proto.getRoleAdmin(ORDER_FILLER_ROLE), ADMIN_ROLE);

        assertTrue(proto.hasRole(proto.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(proto.hasRole(ADMIN_ROLE, admin));
    }

    function test_Initialize_Revert_ZeroAddress() public {
        address implementationAddress = _deploy();

        bytes memory initData_ZeroAsset = _packInitData(address(0), admin, treasury, feeReceiver);
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(implementationAddress, initData_ZeroAsset);

        bytes memory initData_ZeroAdmin = _packInitData(address(asset), address(0), treasury, feeReceiver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new ERC1967Proxy(implementationAddress, initData_ZeroAdmin);

        bytes memory initData_ZeroTreasury = _packInitData(address(asset), admin, address(0), feeReceiver);
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(implementationAddress, initData_ZeroTreasury);

        bytes memory initData_ZeroFeeReceiver = _packInitData(address(asset), admin, treasury, address(0));
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(implementationAddress, initData_ZeroFeeReceiver);
    }

    function test_Initialize_Revert_AlreadyInitialized() public {
        vm.mockCallRevert(
            address(proto),
            _packInitData(address(asset), admin, treasury, feeReceiver),
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
    }

    // Deposit
    function test_Deposit() public {
        _depositAndAssert(user1, 100e6, user2);
    }

    function test_Deposit_Zero() public {
        _depositAndAssert(user1, 0, user2);
    }

    function test_Deposit_Revert_ExceedsMaxDeposit() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _setSupplyCap(tokens);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user2, assets + 1, assets));
        proto.deposit(assets + 1, user2);
    }

    // Mint
    function test_Mint() public {
        _mintAndAssert(user1, 100e18, user2);
    }

    function test_Mint_Zero() public {
        _mintAndAssert(user1, 0, user2);
    }

    function test_Mint_Revert_ExceedsMaxMint() public {
        uint256 tokens = 100e18;
        _setSupplyCap(tokens);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxMint.selector, user2, tokens + 1, tokens));
        proto.mint(tokens + 1, user2);
    }

    // EIP-2612 Permit
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

    // Admin Functions
    function test_WithdrawCollateral() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        proto.withdrawCollateral(50e6, admin);
        assertEq(asset.balanceOf(admin), 50e6);
        assertEq(asset.balanceOf(address(proto)), 50e6);
    }

    function test_WithdrawCollateral_Max() public {
        asset.mint(address(proto), 100e6);
        vm.prank(admin);
        proto.withdrawCollateral(type(uint256).max, admin);
        assertEq(asset.balanceOf(admin), 100e6);
        assertEq(asset.balanceOf(address(proto)), 0);
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

        _createRedeemOrder(user1, 50e18, user1, user1);

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

        _createRedeemOrder(user1, 50e18, user1, user1);

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
    }

    function test_SetRedeemOrderFee_Revert_ExceedsMaxFee() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1_000_001, 1_000_000));
        proto.setRedeemOrderFee(1_000_001);
    }

    function test_SetRedeemOrderFee_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setRedeemOrderFee(100_000);
    }

    function test_SetSupplyCap() public {
        vm.prank(limitManager);
        vm.expectEmit();
        emit UpdatedSupplyCap(type(uint256).max, 200e6);
        proto.setSupplyCap(200e6);
        assertEq(proto.cap(), 200e6);
    }

    function test_SetSupplyCap_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        proto.setSupplyCap(200e6);
    }

    function test_SetFillWindow() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedFillWindow(1 days, 2 days);
        proto.setFillWindow(2 days);
        assertEq(proto.fillWindow(), 2 days);
    }

    function test_SetFillWindow_Revert_TooHigh() public {
        vm.prank(redeemManager);
        vm.expectRevert(abi.encodeWithSelector(FillWindowTooHigh.selector, 365 days + 1, 365 days));
        proto.setFillWindow(365 days + 1);
    }

    function test_SetFillWindow_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setFillWindow(2 days);
    }

    function test_setMinRedeemOrder() public {
        vm.prank(redeemManager);
        vm.expectEmit();
        emit UpdatedMinRedeemOrder(0, 100e18);
        proto.setMinRedeemOrder(100e18);
        assertEq(proto.minRedeemOrder(), 100e18);
    }

    function test_setMinRedeemOrder_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        proto.setMinRedeemOrder(100e18);
    }

    function test_Pause_Unpause() public {
        vm.prank(admin);
        vm.expectEmit();
        emit PausableUpgradeable.Paused(admin);
        proto.pause();
        assertTrue(proto.paused());

        vm.prank(admin);
        vm.expectEmit();
        emit PausableUpgradeable.Unpaused(admin);
        proto.unpause();
        assertFalse(proto.paused());
    }

    function test_Pause_Unpause_Revert_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.pause();

        vm.prank(admin);
        proto.pause();

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        proto.unpause();
    }

    // Misc
    function test_MintRedeem_Revert_Paused() public {
        _depositAndMint(user1, 100e6, 100e6);

        vm.prank(admin);
        proto.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user1, 100e6, 0));
        proto.deposit(100e6, user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxMint.selector, user1, 100e18, 0));
        proto.mint(100e18, user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user1, 100e6, 0));
        proto.withdraw(100e6, user1, user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user1, 100e18, 0));
        proto.redeem(100e18, user1, user1);
        vm.stopPrank();
    }
}

abstract contract YuzuProtoTest_Issuer is YuzuProtoTest {
    // Max Functions
    function test_MaxDeposit_MaxMint() public {
        _setSupplyCap(0);

        assertEq(proto.maxDeposit(user1), 0);
        assertEq(proto.maxMint(user1), 0);

        _setSupplyCap(100e18);

        assertEq(proto.maxDeposit(user1), 100e6);
        assertEq(proto.maxMint(user1), 100e18);
    }

    function test_MaxWithdraw_MaxRedeem() public {
        vm.prank(redeemManager);
        proto.setRedeemFee(250_000); // 25%

        // Limited by balance and buffer
        assertEq(proto.maxWithdraw(user1), 0);
        assertEq(proto.maxRedeem(user1), 0);

        asset.mint(address(proto), 200e6);

        // Limited by balance
        assertEq(proto.maxWithdraw(user1), 0);
        assertEq(proto.maxRedeem(user1), 0);

        _deposit(user1, 300e6);

        // Limited by buffer
        assertEq(proto.maxWithdraw(user1), 160e6);
        assertEq(proto.maxRedeem(user1), 200e18);
    }

    // Withdraw
    function test_Withdraw() public {
        uint256 assets = 100e6;
        _depositAndMint(user1, assets, assets);
        _withdrawAndAssert(user1, assets, user2, user1);
    }

    function test_Withdraw_Zero() public {
        _withdrawAndAssert(user1, 0, user2, user1);
    }

    function test_Withdraw_WithFee() public {
        uint256 assets = 100e6;
        uint256 feePpm = 250_000; // 25%

        vm.prank(redeemManager);
        proto.setRedeemFee(feePpm);

        _depositAndMint(user1, assets, assets);
        _withdrawAndAssert(user1, 80e6, user2, user1);
    }

    function test_Withdraw_Revert_ExceedsMaxWithdraw() public {
        uint256 assets = 100e6;
        _depositAndMint(user1, assets, assets);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user1, assets + 1, assets));
        proto.withdraw(assets + 1, user2, user1);
    }

    function test_Withdraw_Revert_ExceedsMaxWithdraw_LiquidityBuffer() public {
        uint256 assets = 100e6;
        uint256 liquidityBuffer = 50e6;
        uint256 feePpm = 250_000; // 25%

        vm.prank(redeemManager);
        proto.setRedeemFee(feePpm);
        _depositAndMint(user1, assets, liquidityBuffer);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxWithdraw.selector, user1, liquidityBuffer, 40e6));
        proto.withdraw(liquidityBuffer, user2, user1);
    }

    // Redeem
    function test_Redeem() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _depositAndMint(user1, assets, assets);
        _redeemAndAssert(user1, tokens, user2, user1);
    }

    function test_Redeem_Zero() public {
        _redeemAndAssert(user1, 0, user2, user1);
    }

    function test_Redeem_WithFee() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        uint256 feePpm = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemFee(feePpm);

        _depositAndMint(user1, assets, assets);
        _redeemAndAssert(user1, tokens, user2, user1);
    }

    function test_Redeem_Revert_ExceedsMaxRedeem_Balance() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _depositAndMint(user1, assets, assets + 1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user1, tokens + 1, tokens));
        proto.redeem(tokens + 1, user2, user1);
    }

    function test_Redeem_Revert_ExceedsMaxRedeem_LiquidityBuffer() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _depositAndMint(user1, assets + 1, assets);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user1, tokens + 1, tokens));
        proto.redeem(tokens + 1, user2, user1);
    }

    function test_Redeem_Revert_ExceededMaxSlippage() public {
        _depositAndMint(user1, 100e6, 200e6);
        uint256 tokens = 100e18;
        uint256 minAssets = proto.previewRedeem(tokens);

        vm.prank(redeemManager);
        proto.setRedeemFee(100_000); // 10%

        uint256 actualAssets = proto.previewRedeem(tokens);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxSlippage.selector, actualAssets, minAssets));
        proto.redeemWithSlippage(tokens, user1, user1, minAssets);
    }

    // Fuzz
    function testFuzz_Deposit_Withdraw(address caller, address receiver, address owner, uint256 assets, uint256 feePpm)
        public
    {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));

        assets = bound(assets, 0, 1_000_000e6);
        feePpm = bound(feePpm, 0, 1_000_000); // 0% to 100%

        uint256 mintSize = proto.previewDeposit(assets);

        asset.mint(caller, assets);
        _setFees(feePpm, 0);

        vm.prank(admin);
        proto.setTreasury(address(proto));

        _approveAssets(caller, address(proto), assets);
        _depositAndAssert(caller, assets, owner);
        _approveTokens(owner, caller, mintSize);

        uint256 withdrawableAssets = proto.maxWithdraw(owner);
        _withdrawAndAssert(caller, withdrawableAssets, receiver, owner);
    }

    function testFuzz_Mint_Redeem(address caller, address receiver, address owner, uint256 tokens, uint256 feePpm)
        public
    {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));
        tokens = bound(tokens, 1e12, 1_000_000e18);
        feePpm = bound(feePpm, 0, 1_000_000); // 0% to 100%

        uint256 depositSize = proto.previewMint(tokens);

        asset.mint(caller, depositSize);
        _setFees(feePpm, 0);

        vm.prank(admin);
        proto.setTreasury(address(proto));

        _approveAssets(caller, address(proto), depositSize);
        _mintAndAssert(caller, tokens, owner);
        _approveTokens(owner, caller, tokens);

        uint256 redeemableTokens = proto.maxRedeem(owner);
        _redeemAndAssert(caller, redeemableTokens, receiver, owner);
    }

    // Misc
    function test_Preview_FeeRounding() public {
        _setFees(300_000, 0);
        assertEq(proto.previewWithdraw(1), 2e12);
        assertEq(proto.previewWithdraw(9), 12e12);
        assertEq(proto.previewRedeem(1e12), 0);
        assertEq(proto.previewRedeem(9e12), 6);
    }
}

abstract contract YuzuProtoTest_OrderBook is YuzuProtoTest {
    // Max Functions
    function test_MaxWithdraw_MaxRedeem() public {
        vm.prank(redeemManager);
        proto.setRedeemFee(100_000); // 10%

        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 0);

        asset.mint(address(proto), 200e6);

        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 0);

        _deposit(user1, 300e6);

        // Limited by balance
        assertEq(proto.maxRedeemOrder(user1), 300e18);
    }

    // Redeem Orders
    function test_CreateRedeemOrder() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        _createRedeemOrderAndAssert(user1, tokens, user2, user1);
    }

    function test_CreateRedeemOrder_Zero() public {
        _createRedeemOrderAndAssert(user1, 0, user2, user1);
    }

    function test_CreateRedeemOrder_WithFee() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        uint256 feePpm = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(feePpm);

        _deposit(user1, assets);
        _createRedeemOrderAndAssert(user1, tokens, user2, user1);
    }

    function test_CreateRedeemOrder_Revert_ExceedsMaxRedeemOrder() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user1, tokens + 1, tokens));
        proto.createRedeemOrder(tokens + 1, user2, user1);
    }

    function test_CreateRedeemOrder_Revert_UnderMinRedeemOrder() public {
        uint256 minOrder = 50e18;

        vm.prank(redeemManager);
        proto.setMinRedeemOrder(minOrder);

        _deposit(user1, 100e6);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinRedeemOrder.selector, minOrder - 1, minOrder));
        proto.createRedeemOrder(minOrder - 1, user1, user1);
    }

    function test_CreateRedeemOrder_Revert_ZeroReceiver() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _depositAndMint(user1, assets, assets);
        vm.prank(user1);
        vm.expectRevert(InvalidZeroAddress.selector);
        proto.createRedeemOrder(tokens, address(0), user1);
    }

    function test_CreateRedeemOrder_Revert_InsufficientAllowance() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _depositAndMint(user1, assets, assets);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, user2, 0, tokens));
        proto.createRedeemOrder(tokens, user2, user1);
    }

    function test_FillRedeemOrder() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_WithFee() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        uint256 feePpm = 100_000; // 10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(feePpm);

        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_PastDue() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        vm.warp(block.timestamp + proto.fillWindow());
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_Revert_AlreadyFilled() public {
        _deposit(user1, 100e6);
        uint256 orderId = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrder(orderId);

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.fillRedeemOrder(orderId);
    }

    function test_FillRedeemOrder_Revert_Cancelled() public {
        _deposit(user1, 100e6);
        uint256 orderId = _createRedeemOrder(user1, 100e18);
        vm.warp(block.timestamp + proto.fillWindow());
        _cancelRedeemOrder(user1, orderId);

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.fillRedeemOrder(orderId);
    }

    function test_FillRedeemOrder_Revert_NotFiller() public {
        _deposit(user1, 100e6);
        uint256 orderId = _createRedeemOrder(user1, 100e18);

        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, ORDER_FILLER_ROLE)
        );
        proto.fillRedeemOrder(orderId);
    }

    function test_FinalizeRedeemOrder_ByReceiver() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        _fillRedeemOrder(orderId);
        _finalizeRedeemOrderAndAssert(user1, orderId);
    }

    function test_FinalizeRedeemOrder_ByController() public {
        address receiver = user1;
        address controller = user2;
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(receiver, assets);
        _approveTokens(receiver, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, receiver);
        _fillRedeemOrder(orderId);
        _finalizeRedeemOrderAndAssert(receiver, orderId);
    }

    function test_FinalizeRedeemOrder_Revert_AlreadyFilled() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        _fillRedeemOrder(orderId);
        _finalizeRedeemOrder(orderId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, orderId));
        proto.finalizeRedeemOrder(orderId);
    }

    function test_FinalizeRedeemOrder_Revert_NotFilled() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotFilled.selector, orderId));
        proto.finalizeRedeemOrder(orderId);
    }

    function test_FinalizeRedeemOrder_Revert_NotManager() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);
        _fillRedeemOrder(orderId);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderFinalizer.selector, user2, user1, user1));
        proto.finalizeRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_ByOwner() public {
        address owner = user1;
        address controller = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

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
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _cancelRedeemOrderAndAssert(controller, orderId);
    }

    function test_CancelRedeemOrder_Revert_NotDue() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        proto.cancelRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_Revert_AlreadyCancelled() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);

        vm.warp(block.timestamp + proto.fillWindow());

        _cancelRedeemOrder(user1, orderId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        proto.cancelRedeemOrder(orderId);
    }

    function test_CancelRedeemOrder_Revert_NotManager() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(user1, assets);
        uint256 orderId = _createRedeemOrder(user1, tokens);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderManager.selector, user2, user1, user1));
        proto.cancelRedeemOrder(orderId);
    }

    function test_RedeemOrder_Revert_Paused() public {
        _deposit(user1, 200e6);
        uint256 orderId = _createRedeemOrder(user1, 100e18);

        vm.warp(block.timestamp + proto.fillWindow());

        vm.prank(admin);
        proto.pause();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user1, 100e18, 0));
        proto.createRedeemOrder(100e18, user1, user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        proto.cancelRedeemOrder(orderId);
        vm.stopPrank();

        vm.prank(orderFiller);
        proto.fillRedeemOrder(orderId);

        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        proto.finalizeRedeemOrder(orderId);
    }

    // Misc
    function test_Preview_FeeRounding() public {
        _setFees(0, 300_000);
        assertEq(proto.previewRedeemOrder(1e12), 0);
        assertEq(proto.previewRedeemOrder(9e12), 6);
    }
}

contract YuzuProtoHandler is CommonBase, StdCheats, StdUtils {
    bool useGuardrails;

    YuzuProto internal proto;
    ERC20Mock internal asset;
    address internal admin;

    address[] public actors;
    address internal caller;

    uint256[] public activeOrderIds;

    uint256 public distributedAssets;
    uint256 public depositedAssets;
    uint256 public mintedTokens;
    uint256 public withdrawnAssets;
    uint256 public redeemedTokens;
    uint256 public canceledOrderTokens;
    uint256 public collectedFees;

    constructor(YuzuProto _proto, address _admin) {
        useGuardrails = vm.envOr("USE_GUARDRAILS", false);

        proto = _proto;

        asset = ERC20Mock(_proto.asset());
        admin = _admin;

        vm.prank(admin);
        asset.approve(address(proto), type(uint256).max);

        actors.push(makeAddr("user1"));
        actors.push(makeAddr("user2"));
        actors.push(makeAddr("user3"));
        actors.push(makeAddr("user4"));

        for (uint256 i = 0; i < actors.length; i++) {
            address _actor = actors[i];

            vm.prank(_actor);
            asset.approve(address(proto), type(uint256).max);
            vm.prank(_actor);
            proto.approve(address(proto), type(uint256).max);

            for (uint256 j = 0; j < actors.length; j++) {
                if (i != j) {
                    vm.prank(_actor);
                    asset.approve(actors[j], type(uint256).max);
                    vm.prank(_actor);
                    proto.approve(actors[j], type(uint256).max);
                }
            }
        }
    }

    modifier useCaller(uint256 actorIndexSeed) {
        caller = actors[_bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(caller);
        _;
        vm.stopPrank();
    }

    function _getActor(uint256 actorIndexSeed) internal view returns (address) {
        return actors[_bound(actorIndexSeed, 0, actors.length - 1)];
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getActiveOrderIds() external view returns (uint256[] memory) {
        return activeOrderIds;
    }

    function distributeAssets(uint256 assets) public virtual {
        assets = _bound(assets, 0, 1e15);
        distributedAssets += assets;
        asset.mint(address(proto), assets);
    }

    function deposit(uint256 assets, uint256 receiverIndexSeed, uint256 actorIndexSeed)
        public
        virtual
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        assets = _bound(assets, 0, proto.maxDeposit(receiver));
        assets = _bound(assets, 0, 1e15);
        asset.mint(caller, assets);
        depositedAssets += assets;
        mintedTokens += proto.deposit(assets, receiver);
    }

    function mint(uint256 tokens, uint256 receiverIndexSeed, uint256 actorIndexSeed)
        public
        virtual
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        uint256 _maxMint = proto.maxMint(receiver);
        if (useGuardrails && _maxMint < 1e12) return;
        tokens = _bound(tokens, 1e12, _maxMint);
        tokens = _bound(tokens, 1e12, 1e27);
        asset.mint(caller, proto.previewMint(tokens));
        mintedTokens += tokens;
        depositedAssets += proto.mint(tokens, receiver);
    }

    function withdraw(uint256 assets, uint256 receiverIndexSeed, uint256 ownerIndexSeed, uint256 actorIndexSeed)
        public
        virtual
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        address owner = _getActor(ownerIndexSeed);
        assets = _bound(assets, 0, proto.maxWithdraw(owner));

        uint256 tokens = proto.withdraw(assets, receiver, owner);
        uint256 fee = Math.ceilDiv(assets * proto.redeemFeePpm(), 1_000_000);

        withdrawnAssets += assets;
        redeemedTokens += tokens;
        collectedFees += fee;
    }

    function redeem(uint256 tokens, uint256 receiverIndexSeed, uint256 ownerIndexSeed, uint256 actorIndexSeed)
        public
        virtual
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        address owner = _getActor(ownerIndexSeed);
        uint256 _maxRedeem = proto.maxRedeem(owner);
        if (useGuardrails && _maxRedeem < 1e12) return;
        tokens = _bound(tokens, 1e12, _maxRedeem);

        uint256 tokenValue = proto.convertToAssets(tokens);
        uint256 assets = proto.redeem(tokens, receiver, owner);
        uint256 fee = tokenValue - assets;

        redeemedTokens += tokens;
        withdrawnAssets += assets;
        collectedFees += fee;
    }

    function createRedeemOrder(
        uint256 tokens,
        uint256 receiverIndexSeed,
        uint256 ownerIndexSeed,
        uint256 actorIndexSeed
    ) public virtual useCaller(actorIndexSeed) {
        address receiver = _getActor(receiverIndexSeed);
        address owner = _getActor(ownerIndexSeed);
        uint256 _maxRedeem = proto.maxRedeemOrder(owner);
        if (useGuardrails && _maxRedeem < 1e12) return;
        tokens = _bound(tokens, 1e12, _maxRedeem);
        redeemedTokens += tokens;
        uint256 orderId = proto.createRedeemOrder(tokens, receiver, owner);
        activeOrderIds.push(orderId);
    }

    function fillRedeemOrder(uint256 orderIndex) public virtual {
        if (useGuardrails && activeOrderIds.length == 0) return;

        orderIndex = _bound(orderIndex, 0, activeOrderIds.length - 1);
        uint256 orderId = activeOrderIds[orderIndex];
        activeOrderIds[orderIndex] = activeOrderIds[activeOrderIds.length - 1];
        activeOrderIds.pop();
        Order memory order = proto.getRedeemOrder(orderId);

        asset.mint(admin, order.assets);
        vm.prank(admin);
        proto.fillRedeemOrder(orderId);
    }

    function cancelRedeemOrder(uint256 orderIndex, uint256 callerIndex) public virtual {
        if (useGuardrails && activeOrderIds.length == 0) return;

        orderIndex = _bound(orderIndex, 0, activeOrderIds.length - 1);
        uint256 orderId = activeOrderIds[orderIndex];
        activeOrderIds[orderIndex] = activeOrderIds[activeOrderIds.length - 1];
        activeOrderIds.pop();
        Order memory order = proto.getRedeemOrder(orderId);

        if (useGuardrails && order.status != OrderStatus.Pending) return;

        if (callerIndex % 2 == 0) {
            caller = order.owner;
        } else {
            caller = order.controller;
        }

        canceledOrderTokens += order.tokens;
        if (order.dueTime > block.timestamp) vm.warp(order.dueTime);

        vm.prank(caller);
        proto.cancelRedeemOrder(orderId);
    }

    function finalizeRedeemOrder(uint256 orderIndex, uint256 callerIndex) public virtual {
        if (useGuardrails && activeOrderIds.length == 0) return;

        orderIndex = _bound(orderIndex, 0, activeOrderIds.length - 1);
        uint256 orderId = activeOrderIds[orderIndex];
        activeOrderIds[orderIndex] = activeOrderIds[activeOrderIds.length - 1];
        activeOrderIds.pop();
        Order memory order = proto.getRedeemOrder(orderId);

        if (useGuardrails && order.status != OrderStatus.Filled) return;

        if (callerIndex % 2 == 0) {
            caller = order.receiver;
        } else {
            caller = order.controller;
        }

        withdrawnAssets += order.assets;

        vm.prank(caller);
        proto.finalizeRedeemOrder(orderId);
    }

    function setRedeemFee(uint256 newFeePpm) external {
        newFeePpm = _bound(newFeePpm, 0, 1_000_000); // 0 to 100%
        vm.prank(admin);
        proto.setRedeemFee(newFeePpm);
    }

    function setRedeemOrderFee(uint256 newFeePpm) external {
        newFeePpm = _bound(newFeePpm, 0, 1_000_000); // 0% to 100%
        vm.prank(admin);
        proto.setRedeemOrderFee(newFeePpm);
    }
}

abstract contract YuzuProtoInvariantTest is Test {
    YuzuProto public proto;
    YuzuProtoHandler public handler;
    ERC20Mock public asset;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    address public admin;
    address public _treasury;

    function _deploy() internal virtual returns (address);

    function setUp() public virtual {
        admin = makeAddr("admin");
        _treasury = makeAddr("_treasury");

        // Deploy mock asset
        asset = new ERC20Mock();

        // Deploy implementation and proxy-initialize
        address implementationAddress = _deploy();
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(asset),
            "Proto Token",
            "PROTO",
            admin,
            _treasury,
            admin,
            type(uint256).max, // supplyCap
            1 days, // fillWindow
            0 // minRedeemOrder
        );
        ERC1967Proxy proxy = new ERC1967Proxy(implementationAddress, initData);
        proto = YuzuProto(address(proxy));

        vm.startPrank(admin);
        proto.setTreasury(address(proto));
        proto.grantRole(LIMIT_MANAGER_ROLE, admin);
        proto.grantRole(REDEEM_MANAGER_ROLE, admin);
        proto.grantRole(ORDER_FILLER_ROLE, admin);
        vm.stopPrank();

        handler = new YuzuProtoHandler(proto, admin);
        targetContract(address(handler));
    }

    function invariantTest_TotalSupply_Consistent() public view virtual {
        uint256 totalSupply = proto.totalSupply();
        uint256 mintedTokens = handler.mintedTokens();
        uint256 redeemedTokens = handler.redeemedTokens();
        uint256 canceledOrderTokens = handler.canceledOrderTokens();
        uint256 pendingOrderSize = proto.totalPendingOrderSize();
        assertEq(
            totalSupply,
            mintedTokens + canceledOrderTokens + pendingOrderSize - redeemedTokens,
            "! totalSupply == mintedTokens + canceledOrderTokens + pendingOrderSize - redeemedTokens"
        );
    }

    function invariantTest_AssetBalance_Consistent() public view virtual {
        uint256 contractAssetBalance = asset.balanceOf(address(proto));
        uint256 distributedAssets = handler.distributedAssets();
        uint256 depositedAssets = handler.depositedAssets();
        uint256 withdrawnAssets = handler.withdrawnAssets();
        uint256 unfinalizedOrderValue = proto.totalUnfinalizedOrderValue();
        uint256 collectedFees = handler.collectedFees();
        assertEq(
            contractAssetBalance,
            distributedAssets + depositedAssets + unfinalizedOrderValue - withdrawnAssets - collectedFees,
            "! contractAssetBalance == distributedAssets + depositedAssets - unfinalizedOrderValue - withdrawnAssets - collectedFees"
        );
    }

    function invariantTest_TotalAssets_Ge_ImpliedTotalAssets() public view virtual {
        uint256 totalAssets = proto.totalAssets();
        uint256 totalSupply = proto.totalSupply();
        uint256 totalSupplyInAssets = proto.previewRedeem(totalSupply);
        assertGe(totalAssets, totalSupplyInAssets, "! totalAssets >= totalSupplyInAssets");
    }

    function invariantTest_PendingOrderSize_Le_TokenBalance() public view virtual {
        uint256 pendingOrderSize = proto.totalPendingOrderSize();
        uint256 contractTokenBalance = proto.balanceOf(address(proto));
        assertLe(pendingOrderSize, contractTokenBalance, "! pendingOrderSize <= contractTokenBalance");
    }

    function invariantTest_UnfinalizedOrderValue_Le_AssetBalance() public {
        uint256 contractAssetBalance = asset.balanceOf(address(proto));
        uint256 unfinalizedOrderValue = proto.totalUnfinalizedOrderValue();
        assertLe(unfinalizedOrderValue, contractAssetBalance, "! unfinalizedOrderValue <= contractAssetBalance");
    }

    function invariantTest_TotalSupply_Le_SupplyCap() public view virtual {
        assertLe(proto.totalSupply(), proto.cap(), "! totalSupply <= supplyCap");
    }

    function invariantTest_PreviewDepositMaxDeposit_Le_MaxMint() public view virtual {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 maxDeposit = proto.maxDeposit(actor);
            if (maxDeposit < 1e6 || maxDeposit > 1e15) continue;
            uint256 previewDeposit = proto.previewDeposit(maxDeposit);
            assertLe(previewDeposit, proto.maxMint(actor), "! previewDeposit(maxDeposit) <= maxMint");
        }
    }

    function invariantTest_PreviewRedeemMaxRedeem_Le_LiquidityBuffer() public view virtual {
        uint256 liquidityBuffer = proto.liquidityBufferSize();
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 maxRedeem = proto.maxRedeem(actor);
            uint256 previewRedeem = proto.previewRedeem(maxRedeem);
            assertLe(previewRedeem, liquidityBuffer, "! previewRedeem(maxRedeem) <= liquidityBuffer");
        }
    }

    function invariantTest_PreviewWithdrawMaxWithdraw_Le_TokenBalance() public view virtual {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            address actor = actors[i];
            uint256 maxWithdraw = proto.maxWithdraw(actor);
            if (maxWithdraw < 1e6 || maxWithdraw > 1e15) continue;
            uint256 previewWithdraw = proto.previewWithdraw(maxWithdraw);
            uint256 tokenBalance = proto.balanceOf(actor);
            assertLe(previewWithdraw, tokenBalance, "! previewWithdraw(maxWithdraw) <= tokenBalance");
        }
    }
}
