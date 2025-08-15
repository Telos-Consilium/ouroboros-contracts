// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";

contract YuzuUSDTest is YuzuProtoTest {
    function _deploy() internal override returns (address) {
        YuzuUSD yzusd = new YuzuUSD();
        return address(yzusd);
    }

    // Preview Functions
    function test_Preview() public {
        assertEq(proto.previewDeposit(100e6), 100e18);
        assertEq(proto.previewMint(100e18), 100e6);
        assertEq(proto.previewWithdraw(100e6), 100e18);
        assertEq(proto.previewRedeem(100e18), 100e6);
        assertEq(proto.previewRedeemOrder(100e18), 100e6);
    }

    function test_PreviewWithdraw_WithFee() public {
        _setFees(100_000, 200_000); // 10% redemption fee, 20% order fee
        assertEq(proto.previewWithdraw(100e6), 110e18);
        assertEq(proto.previewRedeem(100e18), 90_909090); // 100e6 / (1 + 0.1) = 90.909090
        assertEq(proto.previewRedeemOrder(100e18), 83_333333); // 100e6 / (1 + 0.2) = 83.333333
    }

    function test_PreviewRedeemOrder_WithIncentive() public {
        _setFees(0, -100_000); // 10% incentive on order fee
        assertEq(proto.previewRedeemOrder(100e18), 110000000); // 100e6 * (1 + 0.1) = 110e6
    }

    // Redeem Orders
    function test_FillRedeemOrder_WithIncentive() public {
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        int256 fee = -100_000; // -10%

        vm.prank(redeemManager);
        proto.setRedeemOrderFee(fee);

        _deposit(user1, assets);
        (uint256 orderId,) = _createRedeemOrder(user1, tokens);
        _fillRedeemOrderAndAssert(orderFiller, orderId);
    }

    // Total Assets
    function test_TotalAssets() public {
        _deposit(user1, 100e6);
        assertEq(proto.totalAssets(), 100e6);
    }

    // Fuzz
    function testFuzz_CreateRedeemOrder_FillRedeemOrder(
        address caller,
        address receiver,
        address owner,
        uint256 tokens,
        int256 fee
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));
        vm.assume(caller != orderFiller && receiver != orderFiller && owner != orderFiller);
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

        vm.prank(owner);
        proto.approve(caller, tokens);

        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _fillRedeemOrderAndAssert(orderFiller, proto.orderCount() - 1);
    }
}
