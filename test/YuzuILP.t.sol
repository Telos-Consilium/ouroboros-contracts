// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Test.sol";

import {IYuzuILP} from "../src/interfaces/IYuzuILP.sol";
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

    // Preview functions
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

    function test_Deposit_UpdatesPool() public {
        _deposit(user1, 100e6);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_Withdraw_UpdatesPool() public {
        _setBalances(100e6, 100e6);
        _withdraw(user1, 100e6);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

    function test_CreateRedeemOrder_DoesNotUpdatePool() public {
        _deposit(user1, 100e6);
        _createRedeemOrder(user1, 100e18);
        assertEq(ilp.poolSize(), 100e6);
        assertEq(ilp.totalAssets(), 100e6);
    }

    function test_FillRedeemOrder_UpdatesPool() public {
        _deposit(user1, 100e6);
        (uint256 orderId,) = _createRedeemOrder(user1, 100e18);
        vm.prank(orderFiller);
        ilp.fillRedeemOrder(orderId);
        assertEq(ilp.poolSize(), 0);
        assertEq(ilp.totalAssets(), 0);
    }

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

    function test_TotalAssets() public {
        _updatePool(100e6, 100_000);
        assertEq(ilp.totalAssets(), 100e6);

        vm.warp(ilp.lastPoolUpdateTimestamp() + 1 days / 2);
        assertEq(ilp.totalAssets(), 105e6);

        vm.warp(ilp.lastPoolUpdateTimestamp() + 1 days);
        assertEq(ilp.totalAssets(), 110e6);
    }
}
