// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {IYuzuILPDefinitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {Order} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";

import {YuzuProto} from "../src/proto/YuzuProto.sol";
import {YuzuILP} from "../src/YuzuILP.sol";

import {YuzuProtoTest, YuzuProtoHandler, YuzuProtoInvariantTest} from "./YuzuProto.t.sol";

contract YuzuILPTest is YuzuProtoTest, IYuzuILPDefinitions {
    YuzuILP public ilp;

    address public poolManager;
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    function setUp() public override {
        super.setUp();

        ilp = YuzuILP(address(proto));

        poolManager = makeAddr("poolManager");

        vm.prank(admin);
        ilp.grantRole(POOL_MANAGER_ROLE, poolManager);
    }

    function _deploy() internal override returns (address) {
        YuzuILP minter = new YuzuILP();
        return address(minter);
    }

    // Helpers
    function _updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) internal {
        vm.prank(poolManager);
        ilp.updatePool(newPoolSize, newDailyLinearYieldRatePpm);
    }

    // Preview Functions
    function test_Preview_EmptyPool() public {
        assertEq(ilp.previewDeposit(100e6), 100e18);
        assertEq(ilp.previewMint(100e18), 100e6);
        assertEq(ilp.previewWithdraw(100e6), 0);
        assertEq(ilp.previewRedeem(100e18), 0);
        assertEq(ilp.previewRedeemOrder(100e18), 0);
    }

    function test_Preview_NonEmptyPool() public {
        _deposit(user1, 99e6); // Supply: 99e18
        _updatePool(100e6, 0); // Pool size: 100e6

        assertEq(ilp.previewMint(100e18), uint256(100e6) * 100 / 99 + 1);
        assertEq(ilp.previewRedeem(100e18), uint256(100e6) * 100 / 99);
        assertEq(ilp.previewRedeemOrder(100e18), uint256(100e6) * 100 / 99);

        _updatePool(99e6, 0); // Pool size: 99e6
        _deposit(user1, 1e6); // Supply: 100e18
        _updatePool(99e6, 0); // Pool size: 99e6

        assertEq(ilp.previewDeposit(100e6), uint256(100e18) * 100 / 99);
        assertEq(ilp.previewWithdraw(100e6), uint256(100e18) * 100 / 99 + 1);
    }

    function test_Preview_NonEmptyPool_WithYield() public {
        _deposit(user1, 100e6);
        _updatePool(100e6, 100_000);

        vm.warp(block.timestamp + 1 days);

        assertEq(ilp.previewDeposit(100e6), uint256(100e18) * 10 / 11);
        assertEq(ilp.previewMint(100e18), 110e6);
        assertEq(ilp.previewWithdraw(100e6), 100e18);
        assertEq(ilp.previewRedeem(100e18), 100e6);
        assertEq(ilp.previewRedeemOrder(100e18), 100e6);
    }

    function test_PreviewWithdraw_WithFee() public {
        _deposit(user1, 100e6);
        _setFees(100_000, 200_000);

        assertEq(ilp.previewWithdraw(100e6), 110e18);
        assertEq(ilp.previewRedeem(100e18), 90_909090); // 100e6 / (1 + 0.1) = 90.909090
        assertEq(ilp.previewRedeemOrder(100e18), 83_333333); // 100e6 / (1 + 0.2) = 83.333333
    }

    function test_PreviewWithdraw_WithFeeAndYield() public {
        _deposit(user1, 100e6);
        _updatePool(100e6, 100_000);
        _setFees(100_000, 200_000);

        vm.warp(block.timestamp + 1 days);

        assertEq(ilp.previewWithdraw(100e6), 110e18);
        assertEq(ilp.previewRedeem(100e18), 90_909090); // 100e6 / (1 + 0.1) = 90.909090
        assertEq(ilp.previewRedeemOrder(100e18), 83_333333); // 100e6 / (1 + 0.2) = 83.333333
    }

    function test_PreviewRedeemOrder_WithIncentive() public {
        _deposit(user1, 100e6);
        _setFees(0, -100_000); // 10% incentive on order fee
        assertEq(ilp.previewRedeemOrder(100e18), 110000000); // 100e6 * (1 + 0.1) = 110e6
    }

    // Deposit
    function test_Deposit_UpdatesPool() public {
        _deposit(user1, 100e6);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    // Withdraw
    function test_Withdraw_UpdatesPool() public {
        _setBalances(user1, 100e6, 100e6);
        _withdraw(user1, 100e6);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

    // Redeem Orders
    function test_CreateRedeemOrder_DoesNotUpdatePool() public {
        _deposit(user1, 100e6);
        _createRedeemOrder(user1, 100e18);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_FillRedeemOrder_WithIncentive() public {
        uint256 assets = 100e6;
        uint256 shares = 100e18;
        int256 feePpm = -100_000; // -10%

        vm.prank(redeemManager);
        ilp.setRedeemOrderFee(feePpm);

        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, shares);
        _updatePool(200e6, 0);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_UpdatesPool() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrder(orderId);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

    function testFuzz_CreateRedeemOrder_FillRedeemOrder(
        address caller,
        address receiver,
        address owner,
        uint256 shares,
        int256 feePpm
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(ilp) && receiver != address(ilp) && owner != address(ilp));
        vm.assume(caller != orderFiller && receiver != orderFiller && owner != orderFiller);
        shares = bound(shares, 1e12, 1_000_000e18);
        feePpm = bound(feePpm, -1_000_000, 1_000_000); // -100% to 100%

        uint256 depositSize = ilp.previewMint(shares);

        asset.mint(caller, depositSize);
        _setMaxDepositPerBlock(depositSize);
        _setMaxWithdrawPerBlock(depositSize);
        _setFees(0, feePpm);

        _approveAssets(caller, address(ilp), depositSize);

        vm.prank(caller);
        ilp.mint(shares, owner);

        _updatePool(depositSize, 0);
        _approveTokens(owner, caller, shares);
        _createRedeemOrderAndAssert(caller, shares, receiver, owner);

        vm.warp(block.timestamp + ilp.fillWindow());

        _updatePool(depositSize * 2, 0);
        _fillRedeemOrderAndAssert(orderFiller, ilp.orderCount() - 1);
    }

    // Admin Functions
    function test_UpdatePool() public {
        vm.prank(poolManager);
        ilp.updatePool(100e6, 100_000);

        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.dailyLinearYieldRatePpm(), 100_000);
        assertEq(ilp.lastPoolUpdateTimestamp(), block.timestamp);

        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_UpdatePool_Revert_InvalidYield() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, 1e6 + 1));
        ilp.updatePool(100e6, 1e6 + 1);
    }

    // Total Assets
    function test_TotalAssets() public {
        _updatePool(100e6, 100_000);
        assertEq(ilp.totalAssets(), 100e6);

        vm.warp(ilp.lastPoolUpdateTimestamp() + 1 days / 2);
        assertEq(ilp.totalAssets(), 105e6);

        vm.warp(ilp.lastPoolUpdateTimestamp() + 1 days);
        assertEq(ilp.totalAssets(), 110e6);
    }
}

contract YuzuILPHandler is YuzuProtoHandler {
    YuzuILP public ilp;

    constructor(YuzuProto _proto, address _admin) YuzuProtoHandler(_proto, _admin) {
        ilp = YuzuILP(address(_proto));
    }

    function mint(uint256 shares, uint256 receiverIndexSeed, uint256 actorIndexSeed) public override {
        uint256 totalAssets = ilp.totalAssets();
        if (useGuardrails && totalAssets < 1e18) return;
        super.mint(shares, receiverIndexSeed, actorIndexSeed);
    }

    function withdraw(uint256 assets, uint256 receiverIndexSeed, uint256 ownerIndexSeed, uint256 actorIndexSeed)
        public
        override
    {
        uint256 totalAssets = ilp.totalAssets();
        if (useGuardrails && totalAssets < 1e18) return;
        super.withdraw(assets, receiverIndexSeed, ownerIndexSeed, actorIndexSeed);
    }

    function redeem(uint256 shares, uint256 receiverIndexSeed, uint256 ownerIndexSeed, uint256 actorIndexSeed)
        public
        override
    {
        uint256 totalAssets = ilp.totalAssets();
        if (useGuardrails && totalAssets < 1e18) return;
        super.redeem(shares, receiverIndexSeed, ownerIndexSeed, actorIndexSeed);
    }

    function fillRedeemOrder(uint256 orderIndex) public override {
        if (useGuardrails && activeOrderIds.length == 0) return;

        orderIndex = _bound(orderIndex, 0, activeOrderIds.length - 1);
        uint256 orderId = activeOrderIds[orderIndex];
        activeOrderIds[orderIndex] = activeOrderIds[activeOrderIds.length - 1];
        activeOrderIds.pop();
        Order memory order = ilp.getRedeemOrder(orderId);

        uint256 poolSize = ilp.poolSize();

        if (useGuardrails && order.assets > poolSize) {
            uint256 yieldRatePpm = ilp.dailyLinearYieldRatePpm();
            vm.prank(admin);
            ilp.updatePool(order.assets, yieldRatePpm);
        }

        asset.mint(admin, order.assets);
        vm.prank(admin);
        ilp.fillRedeemOrder(orderId);
    }

    function nextDay(int256 actualYieldRatePpm, uint256 newYieldRatePpm) external {
        actualYieldRatePpm = bound(actualYieldRatePpm, int256(-200_000), int256(200_000));
        newYieldRatePpm = bound(newYieldRatePpm, 0, 200_000);
        vm.warp(block.timestamp + 1 days);
        uint256 totalAssets = ilp.totalAssets();
        uint256 newPoolSize = totalAssets * uint256(1e6 + actualYieldRatePpm) / 1e6;
        vm.prank(admin);
        ilp.updatePool(newPoolSize, newYieldRatePpm);
    }
}

contract YuzuILPInvariantTest is YuzuProtoInvariantTest {
    YuzuILP public ilp;

    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    function _deploy() internal override returns (address) {
        ilp = new YuzuILP();
        return address(ilp);
    }

    function setUp() public override {
        super.setUp();

        vm.prank(admin);
        ilp.grantRole(POOL_MANAGER_ROLE, admin);

        excludeContract(address(handler));

        handler = new YuzuILPHandler(ilp, admin);
        targetContract(address(handler));
    }

    function invariantTest_PreviewMintMaxMint_Le_MaxDeposit() public view override {
        if (ilp.poolSize() > 1e15) return;
        super.invariantTest_PreviewMintMaxMint_Le_MaxDeposit();
    }

    function invariantTest_PreviewDepositMaxDeposit_Le_MaxMint() public view override {
        if (ilp.poolSize() > 1e15) return;
        super.invariantTest_PreviewDepositMaxDeposit_Le_MaxMint();
    }

    function invariantTest_PreviewRedeemMaxRedeem_Le_MaxWithdraw() public view override {
        if (ilp.poolSize() > 1e15) return;
        super.invariantTest_PreviewRedeemMaxRedeem_Le_MaxWithdraw();
    }

    function invariantTest_PreviewWithdrawMaxWithdraw_Le_MaxRedeem() public view override {
        return;
        // if (ilp.poolSize() > 1e15) return;
        // super.invariantTest_PreviewWithdrawMaxWithdraw_Le_MaxRedeem();
    }
}
