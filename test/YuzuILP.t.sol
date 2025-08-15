// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {IYuzuILPDefinitions} from "../src/interfaces/IYuzuILPDefinitions.sol";

import {YuzuILP} from "../src/YuzuILP.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";

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
        uint256 tokens = 100e18;
        int256 fee = -100_000; // -10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(fee);

        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        _updatePool(200e6, 0);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_FillRedeemOrder_UpdatesPool() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        vm.prank(orderFiller);
        ilp.fillRedeemOrder(orderId);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

    function testFuzz_CreateRedeemOrder_FillRedeemOrder(
        address caller, address receiver, address owner, uint256 tokens, int256 fee
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));
        tokens = bound(tokens, 1e12, 1_000_000e18);
        fee = bound(fee, -1_000_000, 1_000_000); // -100% to 100%

        uint256 depositSize = proto.previewMint(tokens);

        asset.mint(caller, depositSize);
        _setMaxDepositPerBlock(depositSize);
        _setMaxWithdrawPerBlock(depositSize);
        _setFees(0, fee);

        vm.prank(caller);
        asset.approve(address(proto), depositSize);

        vm.prank(caller);
        proto.mint(tokens, owner);
        _updatePool(depositSize, 0);

        vm.prank(owner);
        proto.approve(caller, tokens);

        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _updatePool(depositSize * 2, 0);

        _fillRedeemOrderAndAssert(orderFiller, proto.orderCount() - 1);
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
