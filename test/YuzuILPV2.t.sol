// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2, stdError} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuILPV2Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {Order, OrderStatus} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";

import {YuzuILPV2} from "../src/YuzuILPV2.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";
import {YuzuProtoV2Test_Common, YuzuProtoV2Test_OrderBook} from "./YuzuProtoV2.t.sol";
import {YuzuILPTest_Common, YuzuILPTest_OrderBook} from "./YuzuILP.t.sol";

contract YuzuILPV2Test_Common is YuzuILPTest_Common, YuzuProtoV2Test_Common, IYuzuILPV2Definitions {
    YuzuILPV2 public ilp2;

    function setUp() public virtual override(YuzuProtoTest, YuzuILPTest_Common) {
        super.setUp();
        ilp2 = YuzuILPV2(address(proto));
    }

    function _deploy() internal virtual override(YuzuProtoTest, YuzuILPTest_Common) returns (address) {
        return address(new YuzuILPV2());
    }

    // Distribution
    function test_Distribute() public {
        uint256 mintedShares = _deposit(user1, 100e6);

        uint256 initialAssets = ilp2.totalAssets();
        uint256 initialTime = block.timestamp;

        vm.prank(poolManager);
        vm.expectEmit();
        emit Distributed(10e6, 10 hours);
        ilp2.distribute(10e6, 10 hours);

        assertEq(ilp2.lastDistributedAmount(), 10e6);
        assertEq(ilp2.lastDistributionPeriod(), 10 hours);
        assertEq(ilp2.lastDistributionTimestamp(), initialTime);

        assertEq(ilp2.totalAssets(), initialAssets);
        assertEq(ilp2.convertToAssets(mintedShares), 100e6);

        vm.warp(initialTime + 5 hours);
        assertEq(ilp2.totalAssets(), initialAssets + 5e6);
        assertEq(ilp2.convertToAssets(mintedShares), 105e6);

        vm.warp(initialTime + 10 hours);
        assertEq(ilp2.totalAssets(), initialAssets + 10e6);
        assertEq(ilp2.convertToAssets(mintedShares), 110e6);

        vm.warp(initialTime + 15 hours);
        assertEq(ilp2.totalAssets(), initialAssets + 10e6);
        assertEq(ilp2.convertToAssets(mintedShares), 110e6);

        vm.prank(poolManager);
        ilp2.distribute(10e6, 10 hours);
        assertEq(ilp2.totalAssets(), initialAssets + 10e6);

        vm.warp(initialTime + 15 hours + 10 hours);
        assertEq(ilp2.totalAssets(), initialAssets + 20e6);
    }

    function test_FillRedeemOrder_DuringDistribution() public {
        // Deposit assets and set poolSize
        uint256 depositAmount = 100e6;
        uint256 shares = _deposit(user1, depositAmount);
        _updatePool(100e6, 100_000); // 10%

        // Start distribution and advance halfway
        vm.prank(poolManager);
        ilp2.distribute(50e6, 1 hours);
        vm.warp(block.timestamp + 30 minutes);

        // Create redeem order for all shares
        vm.prank(user1);
        uint256 orderId = ilp2.createRedeemOrder(shares, user1, user1);

        // Snapshot accounting before fill
        uint256 poolSizeBefore = ilp2.poolSize();
        uint256 distributedBefore = ilp2.distributedSinceUpdate();
        uint256 totalAssetsBefore = ilp2.totalAssets();

        // Fill the order
        vm.prank(orderFiller);
        ilp2.fillRedeemOrder(orderId);

        // Verify order is filled
        Order memory order = ilp2.getRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));

        // Snapshot after fill
        uint256 poolSizeAfter = ilp2.poolSize();
        uint256 distributedAfter = ilp2.distributedSinceUpdate();
        uint256 totalAssetsAfter = ilp2.totalAssets();

        assertLt(poolSizeAfter, poolSizeBefore);
        assertEq(distributedAfter, distributedBefore);
        assertEq(totalAssetsAfter, totalAssetsBefore - order.assets); // - fee
    }

    function test_Distribute_Revert_NotPoolManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, POOL_MANAGER_ROLE)
        );
        ilp2.distribute(1e6, 1 days);
    }

    function test_Distribute_Revert_PeriodTooLow() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 0, 1));
        ilp2.distribute(1e6, 0);
    }

    function test_Distribute_Revert_PeriodTooHigh() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooHigh.selector, 7 days + 1, 7 days));
        ilp2.distribute(1e6, 7 days + 1);
    }

    function test_Distribute_Revert_InProgress() public {
        uint256 initialTime = block.timestamp;

        vm.startPrank(poolManager);

        ilp2.distribute(1e6, 1 days);

        vm.expectRevert(abi.encodeWithSelector(DistributionInProgress.selector));
        ilp2.distribute(1e6, 1 days);

        vm.warp(initialTime + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(DistributionInProgress.selector));
        ilp2.distribute(1e6, 1 days);

        vm.warp(initialTime + 1 days);
        ilp2.distribute(1e6, 1 days);

        vm.stopPrank();
    }

    function test_TerminateDistribution() public {
        // uint256 initialTime = block.timestamp;
        // uint32 cast prevents unexpected compiler behavior
        uint256 initialTime = uint256(uint32(block.timestamp));

        vm.prank(poolManager);
        ilp2.distribute(10e6, 10 hours);

        vm.warp(initialTime + 1 hours);

        vm.prank(poolManager);
        vm.expectEmit();
        emit TerminatedDistribution(9e6);
        ilp2.terminateDistribution();

        assertEq(ilp2.lastDistributedAmount(), 1e6);
        assertEq(ilp2.lastDistributionPeriod(), 1 hours);
        assertEq(ilp2.lastDistributionTimestamp(), initialTime);

        assertEq(ilp2.totalAssets(), 1e6);

        vm.warp(initialTime + 10 hours);

        assertEq(ilp2.totalAssets(), 1e6);
    }

    function test_TerminateDistribution_Revert_NotPoolManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, POOL_MANAGER_ROLE)
        );
        ilp2.terminateDistribution();
    }

    function test_TerminateDistribution_Revert_NotInProgress() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(NoDistributionInProgress.selector));
        ilp2.terminateDistribution();

        vm.prank(poolManager);
        ilp2.distribute(1e6, 1 days);

        vm.warp(block.timestamp + 1 days);

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(NoDistributionInProgress.selector));
        ilp2.terminateDistribution();
    }

    function test_TerminateDistribution_SameBlock() public {
        vm.prank(poolManager);
        ilp2.distribute(1e6, 1 days);
        vm.prank(poolManager);
        ilp2.terminateDistribution();
        ilp2.totalAssets();
    }
}

contract YuzuILPV2Test_OrderBook is YuzuILPTest_OrderBook, YuzuProtoV2Test_OrderBook {
    function _deploy() internal virtual override(YuzuProtoTest, YuzuILPTest_OrderBook) returns (address) {
        return address(new YuzuILPV2());
    }
}
