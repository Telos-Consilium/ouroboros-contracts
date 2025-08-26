// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Order, OrderStatus} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IStakedYuzuUSDDefinitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

contract StakedYuzuUSDTest is IStakedYuzuUSDDefinitions, Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    StakedYuzuUSD public styz;
    ERC20Mock public yzusd;
    address public owner;
    address public user1;
    address public user2;

    uint256 public user1key;
    uint256 public user2key;

    function setUp() public {
        owner = makeAddr("owner");

        Vm.Wallet memory user1Wallet = vm.createWallet("user1");
        user1 = user1Wallet.addr;
        user1key = user1Wallet.privateKey;

        Vm.Wallet memory user2Wallet = vm.createWallet("user2");
        user2 = user2Wallet.addr;
        user2key = user2Wallet.privateKey;

        // Deploy mock asset and mint balances
        yzusd = new ERC20Mock();
        yzusd.mint(user1, 10_000_000e18);
        yzusd.mint(user2, 10_000_000e18);

        // Deploy implementation and proxy-initialize
        StakedYuzuUSD implementation = new StakedYuzuUSD();
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector, IERC20(address(yzusd)), "Staked Yuzu USD", "st-yzUSD", owner, 1 days
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        styz = StakedYuzuUSD(address(proxy));

        // Approvals for deposits/orders
        _approveAssets(user1, address(styz), type(uint256).max);
        _approveAssets(user2, address(styz), type(uint256).max);
    }

    // Helpers
    function _approveAssets(address _owner, address spender, uint256 amount) internal {
        vm.prank(_owner);
        yzusd.approve(spender, amount);
    }

    function _approveShares(address _owner, address spender, uint256 tokens) internal {
        vm.prank(_owner);
        styz.approve(spender, tokens);
    }

    function _deposit(address caller, uint256 assets, address receiver) internal returns (uint256 tokens) {
        vm.prank(caller);
        return styz.deposit(assets, receiver);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 tokens) {
        return _deposit(user, assets, user);
    }

    function _initiateRedeem(address caller, uint256 shares, address receiver, address _owner)
        internal
        returns (uint256 orderId, uint256 assets)
    {
        vm.prank(caller);
        return styz.initiateRedeem(shares, receiver, _owner);
    }

    function _initiateRedeem(address user, uint256 shares) internal returns (uint256 orderId, uint256 assets) {
        return _initiateRedeem(user, shares, user, user);
    }

    function _finalizeRedeem(address caller, uint256 orderId) internal {
        vm.prank(caller);
        styz.finalizeRedeem(orderId);
    }

    // Initialization
    function test_Initialize() public {
        assertEq(address(styz.asset()), address(yzusd));
        assertEq(styz.name(), "Staked Yuzu USD");
        assertEq(styz.symbol(), "st-yzUSD");
        assertEq(styz.owner(), owner);
        assertEq(styz.redeemDelay(), 1 days);
    }

    function _packInitData(address _asset, address _owner) internal returns (bytes memory) {
        return abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector, IERC20(_asset), "Staked Yuzu USD", "st-yzUSD", _owner, 1 days
        );
    }

    function test_Initialize_Revert_ZeroAddress() public {
        StakedYuzuUSD implementation = new StakedYuzuUSD();

        bytes memory initData_ZeroAsset = _packInitData(address(0), owner);
        vm.expectRevert(InvalidZeroAddress.selector);
        new ERC1967Proxy(address(implementation), initData_ZeroAsset);

        bytes memory initData_ZeroOwner = _packInitData(address(yzusd), address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
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
        uint256 mintedShares = _deposit(user1, 100e18);
        _initiateRedeemAndAssert(user1, mintedShares, user1, user1);
    }

    function test_InitiateRedeem_Zero() public {
        _initiateRedeemAndAssert(user1, 0, user1, user1);
    }

    function test_InitiateRedeem_WithFee() public {
        uint256 feePpm = 100_000; // 10%

        vm.prank(owner);
        styz.setRedeemFee(feePpm);

        uint256 mintedShares = _deposit(user1, 100e18);
        _initiateRedeemAndAssert(user1, mintedShares, user1, user1);
    }

    function test_InitiateRedeem_Revert_ExceedsMaxRedeem() public {
        uint256 mintedShares = _deposit(user1, 100e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, mintedShares + 1, mintedShares
            )
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
        address _owner = user1;
        address sender = user2;
        uint256 mintedShares = _deposit(_owner, 100e18);
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, sender, 0, mintedShares)
        );
        styz.initiateRedeem(mintedShares, sender, _owner);
    }

    // Redeem Finalization
    function _finalizeRedeemAndAssert(address caller, uint256 orderId) internal {
        Order memory order = styz.getRedeemOrder(orderId);

        uint256 receiverAssetsBefore = yzusd.balanceOf(order.receiver);
        uint256 contractAssetsBefore = yzusd.balanceOf(address(styz));
        uint256 pendingOrderValueBefore = styz.totalPendingOrderValue();

        vm.prank(caller);
        vm.expectEmit();
        emit FinalizedRedeem(caller, order.receiver, order.owner, orderId, order.assets, order.shares);
        vm.expectEmit();
        emit IERC4626.Withdraw(caller, order.receiver, order.owner, order.assets, order.shares);
        styz.finalizeRedeem(orderId);

        Order memory orderAfter = styz.getRedeemOrder(orderId);
        assertEq(uint256(orderAfter.status), uint256(OrderStatus.Executed));

        assertEq(yzusd.balanceOf(order.receiver), receiverAssetsBefore + order.assets);
        assertEq(yzusd.balanceOf(address(styz)), contractAssetsBefore - order.assets);
        assertEq(styz.totalPendingOrderValue(), pendingOrderValueBefore - order.assets);
    }

    function test_FinalizeRedeem_ByReceiver() public {
        address _owner = user1;
        address receiver = user2;
        uint256 mintedShares = _deposit(_owner, 100e18);
        (uint256 orderId,) = _initiateRedeem(_owner, mintedShares, receiver, _owner);
        vm.warp(block.timestamp + styz.redeemDelay());
        _finalizeRedeemAndAssert(receiver, orderId);
    }

    function test_FinalizeRedeem_ByController() public {
        address _owner = user2;
        address controller = user1;
        uint256 mintedShares = _deposit(_owner, 100e18);
        _approveShares(_owner, controller, mintedShares);
        (uint256 orderId,) = _initiateRedeem(controller, mintedShares, _owner, _owner);
        vm.warp(block.timestamp + styz.redeemDelay());
        _finalizeRedeemAndAssert(controller, orderId);
    }

    function test_FinalizeRedeem_Revert_ByOwner() public {
        address _owner = user2;
        address controller = user1;
        address receiver = makeAddr("receiver");
        uint256 mintedShares = _deposit(_owner, 100e18);
        _approveShares(_owner, controller, mintedShares);
        (uint256 orderId,) = _initiateRedeem(controller, mintedShares, receiver, _owner);
        vm.warp(block.timestamp + styz.redeemDelay());

        vm.prank(_owner);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderFinalizer.selector, _owner, receiver, controller));
        styz.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_Revert_InvalidOrder() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderFinalizer.selector, user1, address(0), address(0)));
        styz.finalizeRedeem(999);
    }

    function test_FinalizeRedeem_Revert_NotDue() public {
        uint256 mintedShares = _deposit(user1, 200e18);
        (uint256 orderId,) = _initiateRedeem(user1, mintedShares);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_Revert_NotPending() public {
        uint256 mintedShares = _deposit(user1, 200e18);
        (uint256 orderId,) = _initiateRedeem(user1, mintedShares);
        vm.warp(block.timestamp + styz.redeemDelay());
        _finalizeRedeem(user1, orderId);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        styz.finalizeRedeem(orderId);
    }

    function test_FinalizeRedeem_Revert_NotFinalizer() public {
        uint256 mintedShares = _deposit(user1, 200e18);
        (uint256 orderId,) = _initiateRedeem(user1, mintedShares);
        vm.warp(block.timestamp + styz.redeemDelay());

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedOrderFinalizer.selector, user2, user1, user1));
        styz.finalizeRedeem(orderId);
    }

    // Fuzz
    function testFuzz_InitiateRedeem_FinalizeRedeem(
        address caller,
        address receiver,
        address _owner,
        uint256 shares,
        uint256 feePpm
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && _owner != address(0));
        vm.assume(caller != address(styz) && receiver != address(styz) && _owner != address(styz));
        shares = bound(shares, 1e12, 1_000_000e18);
        feePpm = bound(feePpm, 0, 1_000_000); // 0% to 100%

        uint256 depositSize = styz.previewMint(shares);

        yzusd.mint(_owner, depositSize);

        _approveAssets(_owner, address(styz), depositSize);
        _deposit(_owner, depositSize, _owner);
        _approveShares(_owner, caller, shares);

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
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        styz.rescueTokens(address(otherAsset), user1, 50e18);
    }

    function test_Setters() public {
        vm.startPrank(owner);
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
        // Set Redeem Fee
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        styz.setRedeemFee(100_000);
        // Set Redeem Delay
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
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
        uint256 mintedShares = _deposit(user1, depositAmount);
        assertEq(styz.totalAssets(), initialAssets + depositAmount);
        _initiateRedeem(user1, mintedShares);
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

    // Permit
    function test_Permit() public {
        address _owner = user1;
        uint256 ownerPrivateKey = user1key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = styz.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", styz.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        assertEq(styz.allowance(_owner, spender), 0);

        styz.permit(_owner, spender, value, deadline, v, r, s);

        assertEq(styz.allowance(_owner, spender), value);
        assertEq(styz.nonces(_owner), nonce + 1);
    }

    function test_Permit_Revert_InvalidSigner() public {
        address _owner = user1;
        uint256 invalidPrivateKey = user2key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = styz.nonces(_owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", styz.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(invalidPrivateKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, user2, user1));
        styz.permit(_owner, spender, value, deadline, v, r, s);
    }

    function test_Permit_Revert_ExpiredSignature() public {
        address _owner = user1;
        uint256 ownerPrivateKey = user2key;
        address spender = user2;
        uint256 value = 123e18;
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = styz.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, _owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", styz.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        styz.permit(_owner, spender, value, deadline, v, r, s);
    }
}

contract StakedYuzuUSDHandler is CommonBase, StdCheats, StdUtils {
    bool useGuardrails;

    StakedYuzuUSD internal styz;
    ERC20Mock internal yzusd;
    address internal owner;

    address[] public actors;
    address internal caller;

    uint256[] public activeOrderIds;

    uint256 public donatedAssets;
    uint256 public depositedAssets;
    uint256 public mintedShares;
    uint256 public withdrawnAssets;
    uint256 public redeemedShares;

    constructor(StakedYuzuUSD _styz) {
        useGuardrails = vm.envOr("USE_GUARDRAILS", false);

        styz = _styz;

        yzusd = ERC20Mock(_styz.asset());
        owner = _styz.owner();

        actors.push(makeAddr("user1"));
        actors.push(makeAddr("user2"));
        actors.push(makeAddr("user3"));
        actors.push(makeAddr("user4"));

        for (uint256 i = 0; i < actors.length; i++) {
            address _actor = actors[i];

            vm.prank(_actor);
            yzusd.approve(address(styz), type(uint256).max);
            vm.prank(_actor);
            styz.approve(address(styz), type(uint256).max);

            for (uint256 j = 0; j < actors.length; j++) {
                if (i != j) {
                    vm.prank(_actor);
                    yzusd.approve(actors[j], type(uint256).max);
                    vm.prank(_actor);
                    styz.approve(actors[j], type(uint256).max);
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

    function donateAssets(uint256 assets) external {
        assets = _bound(assets, 0, 1e27);
        donatedAssets += assets;
        yzusd.mint(address(styz), assets);
    }

    function deposit(uint256 assets, uint256 receiverIndexSeed, uint256 actorIndexSeed)
        external
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        assets = _bound(assets, 0, styz.maxDeposit(receiver));
        assets = _bound(assets, 0, 1e27);
        yzusd.mint(caller, assets);
        depositedAssets += assets;
        mintedShares += styz.deposit(assets, receiver);
    }

    function mint(uint256 shares, uint256 receiverIndexSeed, uint256 actorIndexSeed)
        external
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        shares = _bound(shares, 0, styz.maxMint(receiver));
        shares = _bound(shares, 0, 1e27);
        yzusd.mint(caller, styz.previewMint(shares));
        mintedShares += shares;
        depositedAssets += styz.mint(shares, receiver);
    }

    function initiateRedeem(uint256 shares, uint256 receiverIndexSeed, uint256 ownerIndexSeed, uint256 actorIndexSeed)
        external
        useCaller(actorIndexSeed)
    {
        address receiver = _getActor(receiverIndexSeed);
        address _owner = _getActor(ownerIndexSeed);
        shares = _bound(shares, 0, styz.maxRedeem(_owner));
        redeemedShares += shares;
        (uint256 orderId,) = styz.initiateRedeem(shares, receiver, _owner);
        activeOrderIds.push(orderId);
    }

    function finalizeRedeem(uint256 orderIndex, uint256 callerIndex) external {
        if (useGuardrails && activeOrderIds.length == 0) return;

        orderIndex = _bound(orderIndex, 0, activeOrderIds.length - 1);
        uint256 orderId = activeOrderIds[orderIndex];
        activeOrderIds[orderIndex] = activeOrderIds[activeOrderIds.length - 1];
        activeOrderIds.pop();
        Order memory order = styz.getRedeemOrder(orderId);

        if (callerIndex % 2 == 0) {
            caller = order.receiver;
        } else {
            caller = order.controller;
        }

        withdrawnAssets += order.assets;
        if (order.dueTime > block.timestamp) vm.warp(order.dueTime);

        vm.prank(caller);
        styz.finalizeRedeem(orderId);
    }

    function setRedeemFee(uint256 newFeePpm) external {
        newFeePpm = _bound(newFeePpm, 0, 1_000_000); // 0 to 100%
        vm.prank(owner);
        styz.setRedeemFee(newFeePpm);
    }
}

contract StakedYuzuUSDInvariantTest is Test {
    StakedYuzuUSD public styz;
    StakedYuzuUSDHandler public handler;
    ERC20Mock public yzusd;

    function setUp() public {
        // Deploy mock asset
        yzusd = new ERC20Mock();

        // Deploy implementation and proxy-initialize
        StakedYuzuUSD implementation = new StakedYuzuUSD();
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            makeAddr("owner"),
            1 days
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        styz = StakedYuzuUSD(address(proxy));

        handler = new StakedYuzuUSDHandler(styz);
        targetContract(address(handler));
    }

    function invariantTest_ShareBalance_Zero() public view {
        uint256 contractShareBalance = styz.balanceOf(address(styz));
        assertEq(contractShareBalance, 0, "! contractShareBalance == 0");
    }

    function invariantTest_TotalSupply_Consistent() public view {
        uint256 totalSupply = styz.totalSupply();
        uint256 mintedShares = handler.mintedShares();
        uint256 redeemedShares = handler.redeemedShares();
        assertEq(totalSupply, mintedShares - redeemedShares, "! totalSupply == mintedShares - redeemedShares");
    }

    function invariantTest_AssetBalance_Consistent() public view {
        uint256 contractAssetBalance = yzusd.balanceOf(address(styz));
        uint256 donatedAssets = handler.donatedAssets();
        uint256 depositedAssets = handler.depositedAssets();
        uint256 withdrawnAssets = handler.withdrawnAssets();
        assertEq(
            contractAssetBalance,
            donatedAssets + depositedAssets - withdrawnAssets,
            "! contractAssetBalance == donatedAssets + depositedAssets - withdrawnAssets"
        );
    }

    function invariantTest_PendingOrderValue_Consistent() public view {
        uint256 totalPendingOrderValue = styz.totalPendingOrderValue();
        uint256[] memory _activeOrderIds = handler.getActiveOrderIds();

        uint256 _totalPendingOrderValue = 0;
        for (uint256 i = 0; i < _activeOrderIds.length; i++) {
            Order memory order = styz.getRedeemOrder(_activeOrderIds[i]);
            _totalPendingOrderValue += order.assets;
        }

        assertEq(totalPendingOrderValue, _totalPendingOrderValue, "! totalPendingOrderValue == _totalPendingOrderValue");
    }
}
