// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IYuzuILPDefinitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {Order} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";

import {YuzuProto} from "../src/proto/YuzuProto.sol";
import {YuzuILP} from "../src/YuzuILP.sol";

import {
    YuzuProtoTest_Common,
    YuzuProtoTest_Issuer,
    YuzuProtoTest_OrderBook,
    YuzuProtoHandler,
    YuzuProtoInvariantTest
} from "./YuzuProto.t.sol";

contract YuzuILPTest_Common is YuzuProtoTest_Common, IYuzuILPDefinitions {
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
        return address(new YuzuILP());
    }

    // Helpers
    function _pause() internal {
        vm.prank(admin);
        ilp.pause();
    }

    function _unpause() internal {
        vm.prank(admin);
        ilp.unpause();
    }

    function _updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) internal {
        _pause();
        uint256 currentPoolSize = ilp.poolSize();
        vm.prank(poolManager);
        ilp.updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
        _unpause();
    }

    // Preview Functions
    function test_Preview_EmptyPool() public {
        assertEq(ilp.previewDeposit(100e6), 100e18);
        assertEq(ilp.previewMint(100e18), 100e6);
        assertEq(ilp.previewWithdraw(100e6), 100e18);
        assertEq(ilp.previewRedeem(100e18), 100e6);
        assertEq(ilp.previewRedeemOrder(100e18), 100e6);
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
        assertEq(ilp.previewWithdraw(110e6), 100e18);
        assertEq(ilp.previewRedeem(100e18), 110e6);
        assertEq(ilp.previewRedeemOrder(100e18), 110e6);
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
        _setFees(250_000, 500_000);

        vm.warp(block.timestamp + 1 days);

        assertEq(ilp.previewWithdraw(110e6), 125e18); // 100e18 * 1.25
        assertEq(ilp.previewRedeem(100e18), 88_000000); // 110e6 / (1 + 0.25)
        assertEq(ilp.previewRedeemOrder(100e18), 73_333333); // 110e6 / (1 + 0.5)
    }

    // Deposit
    function test_Deposit_UpdatesPool() public {
        _deposit(user1, 100e6);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_Deposit_EmptyPool_WithYield() public {
        _updatePool(0, 500_000);
        vm.warp(block.timestamp + 1 days);
        _deposit(user1, 150e6);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 150e6);
    }

    // Redeem Orders
    function test_CreateRedeemOrder_DoesNotUpdatePool() public {
        _deposit(user1, 100e6);
        _createRedeemOrder(user1, 100e18);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_FillRedeemOrder_UpdatesPool() public {
        _deposit(user1, 100e6);
        uint256 orderId = _createRedeemOrder(user1, 100e18);
        _fillRedeemOrder(orderId);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

    function testFuzz_CreateRedeemOrder_FillRedeemOrder(
        address caller,
        address receiver,
        address owner,
        uint256 shares,
        uint256 feePpm
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(ilp) && receiver != address(ilp) && owner != address(ilp));
        vm.assume(caller != orderFiller && receiver != orderFiller && owner != orderFiller);
        shares = bound(shares, 1e12, 1_000_000e18);
        feePpm = bound(feePpm, 0, 1_000_000); // 0% to 100%

        uint256 depositSize = ilp.previewMint(shares);

        asset.mint(caller, depositSize);
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
        _pause();
        vm.prank(poolManager);
        vm.expectEmit();
        emit UpdatedPool(0, 100e6, 100_000);
        ilp.updatePool(0, 100e6, 100_000);

        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.dailyLinearYieldRatePpm(), 100_000);
        assertEq(ilp.lastPoolUpdateTimestamp(), block.timestamp);

        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_UpdatePool_Revert_NotPaused() public {
        vm.prank(poolManager);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        ilp.updatePool(0, 100e6, 1e6 + 1);
    }

    function test_UpdatePool_Revert_InvalidCurrentPoolSize() public {
        _pause();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InvalidCurrentPoolSize.selector, 1, 0));
        ilp.updatePool(1, 100e6, 1e6 + 1);
    }

    function test_UpdatePool_Revert_InvalidYield() public {
        _pause();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(InvalidYield.selector, 1e6 + 1));
        ilp.updatePool(0, 100e6, 1e6 + 1);
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

contract YuzuUSDTest_OrderBook is YuzuProtoTest_OrderBook {
    function _deploy() internal override returns (address) {
        return address(new YuzuILP());
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
            vm.startPrank(admin);
            ilp.pause();
            ilp.updatePool(poolSize, order.assets, yieldRatePpm);
            ilp.unpause();
            vm.stopPrank();
        }

        asset.mint(admin, order.assets);
        vm.prank(admin);
        ilp.fillRedeemOrder(orderId);
    }

    function nextDay(int256 actualYieldRatePpm, uint256 newYieldRatePpm) external {
        actualYieldRatePpm = bound(actualYieldRatePpm, int256(-1_000_000), int256(10_000_000)); // -100% to 1000%
        newYieldRatePpm = bound(newYieldRatePpm, 0, 1_000_000); // 0% to 100%
        vm.warp(block.timestamp + 1 days);
        uint256 currentPoolSize = ilp.poolSize();
        uint256 newPoolSize = currentPoolSize * uint256(1e6 + actualYieldRatePpm) / 1e6;
        newPoolSize = _bound(newPoolSize, 0, 1e36);
        vm.startPrank(admin);
        ilp.pause();
        ilp.updatePool(currentPoolSize, newPoolSize, newYieldRatePpm);
        ilp.unpause();
        vm.stopPrank();
    }
}

contract YuzuILPInvariantTest is YuzuProtoInvariantTest {
    YuzuILP public ilp;

    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    function _deploy() internal override returns (address) {
        return address(new YuzuILP());
    }

    function setUp() public override {
        super.setUp();

        ilp = YuzuILP(address(proto));

        vm.prank(admin);
        ilp.grantRole(POOL_MANAGER_ROLE, admin);

        excludeContract(address(handler));

        handler = new YuzuILPHandler(ilp, admin);
        targetContract(address(handler));
    }
}
