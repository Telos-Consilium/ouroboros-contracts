// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuILPV2Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {Order} from "../src/interfaces/proto/IYuzuOrderBookDefinitions.sol";

import {YuzuILPV2} from "../src/YuzuILPV2.sol";

import {YuzuILPTest_Common, YuzuILPTest_OrderBook} from "./YuzuILP.t.sol";

contract YuzuILPV2Test_Common is YuzuILPTest_Common, IYuzuILPV2Definitions {
    YuzuILPV2 public ilpv2;

    function setUp() public virtual override {
        super.setUp();
        ilpv2 = YuzuILPV2(address(proto));
        ilpv2.initializeV2();
        assertEq(ilpv2.lastDistributionPeriod(), 1);
    }

    function _deploy() internal virtual override returns (address) {
        return address(new YuzuILPV2());
    }

    // Distribution
    function test_Distribute() public {
        uint256 mintedShares = _deposit(user1, 100e6);

        uint256 initialAssets = ilpv2.totalAssets();
        uint256 initialTime = block.timestamp;

        vm.prank(poolManager);
        vm.expectEmit();
        emit Distributed(10e6, 10 hours);
        ilpv2.distribute(10e6, 10 hours);

        assertEq(ilpv2.lastDistributedAmount(), 10e6);
        assertEq(ilpv2.lastDistributionPeriod(), 10 hours);
        assertEq(ilpv2.lastDistributionTimestamp(), initialTime);

        assertEq(ilpv2.totalAssets(), initialAssets);
        assertEq(ilpv2.convertToAssets(mintedShares), 100e6);

        vm.warp(initialTime + 5 hours);
        assertEq(ilpv2.totalAssets(), initialAssets + 5e6);
        assertEq(ilpv2.convertToAssets(mintedShares), 105e6);

        vm.warp(initialTime + 10 hours);
        assertEq(ilpv2.totalAssets(), initialAssets + 10e6);
        assertEq(ilpv2.convertToAssets(mintedShares), 110e6);

        vm.warp(initialTime + 15 hours);
        assertEq(ilpv2.totalAssets(), initialAssets + 10e6);
        assertEq(ilpv2.convertToAssets(mintedShares), 110e6);
    }

    function test_Distribute_Revert_NotPoolManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, POOL_MANAGER_ROLE)
        );
        ilpv2.distribute(1e6, 1 days);
    }

    function test_Distribute_Revert_PeriodTooLow() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 0, 1));
        ilpv2.distribute(1e6, 0);
    }

    function test_Distribute_Revert_PeriodTooHigh() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooHigh.selector, 7 days + 1, 7 days));
        ilpv2.distribute(1e6, 7 days + 1);
    }

    function test_Distribute_Revert_InProgress() public {
        uint256 initialTime = block.timestamp;

        vm.startPrank(poolManager);

        ilpv2.distribute(1e6, 1 days);

        vm.expectRevert(abi.encodeWithSelector(DistributionInProgress.selector));
        ilpv2.distribute(1e6, 1 days);

        vm.warp(initialTime + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(DistributionInProgress.selector));
        ilpv2.distribute(1e6, 1 days);

        vm.warp(initialTime + 1 days);
        ilpv2.distribute(1e6, 1 days);

        vm.stopPrank();
    }

    function test_TerminateDistribution() public {
        // uint256 initialTime = block.timestamp;
        // uint32 cast prevents unexpected compiler behavior
        uint256 initialTime = uint256(uint32(block.timestamp));

        vm.prank(poolManager);
        ilpv2.distribute(10e6, 10 hours);

        vm.warp(initialTime + 1 hours);

        vm.prank(poolManager);
        vm.expectEmit();
        emit TerminatedDistribution(9e6);
        ilpv2.terminateDistribution();

        assertEq(ilpv2.lastDistributedAmount(), 1e6);
        assertEq(ilpv2.lastDistributionPeriod(), 1 hours);
        assertEq(ilpv2.lastDistributionTimestamp(), initialTime);

        assertEq(ilpv2.totalAssets(), 1e6);

        vm.warp(initialTime + 10 hours);

        assertEq(ilpv2.totalAssets(), 1e6);
    }

    function test_TerminateDistribution_Revert_NotPoolManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, POOL_MANAGER_ROLE)
        );
        ilpv2.terminateDistribution();
    }

    function test_TerminateDistribution_Revert_NotInProgress() public {
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(NoDistributionInProgress.selector));
        ilpv2.terminateDistribution();

        vm.prank(poolManager);
        ilpv2.distribute(1e6, 1 days);

        vm.warp(block.timestamp + 1 days);

        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(NoDistributionInProgress.selector));
        ilpv2.terminateDistribution();
    }

    function test_TerminateDistribution_SameBlock() public {
        vm.prank(poolManager);
        ilpv2.distribute(1e6, 1 days);
        vm.prank(poolManager);
        ilpv2.terminateDistribution();
        ilpv2.totalAssets();
    }
}

contract YuzuILPV2Test_OrderBook is YuzuILPTest_OrderBook {
    function _deploy() internal virtual override returns (address) {
        return address(new YuzuILPV2());
    }
}
