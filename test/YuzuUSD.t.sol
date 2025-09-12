// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";

import {
    YuzuProtoTest_Common,
    YuzuProtoTest_Issuer,
    YuzuProtoTest_OrderBook,
    YuzuProtoInvariantTest
} from "./YuzuProto.t.sol";

contract YuzuUSDTest_Common is YuzuProtoTest_Common {
    function _deploy() internal override returns (address) {
        return address(new YuzuUSD());
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
        uint256 feePpm
    ) public {
        vm.assume(caller != address(0) && receiver != address(0) && owner != address(0));
        vm.assume(caller != address(proto) && receiver != address(proto) && owner != address(proto));
        vm.assume(caller != orderFiller && receiver != orderFiller && owner != orderFiller);
        tokens = bound(tokens, 1e12, 1_000_000e18);
        feePpm = bound(feePpm, 0, 1_000_000); // 0% to 100%

        uint256 depositSize = proto.previewMint(tokens);

        asset.mint(caller, depositSize);
        _setFees(0, feePpm);

        _approveAssets(caller, address(proto), depositSize);

        vm.prank(caller);
        proto.mint(tokens, owner);

        _approveTokens(owner, caller, tokens);
        _createRedeemOrderAndAssert(caller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _fillRedeemOrderAndAssert(orderFiller, proto.orderCount() - 1);
    }
}

contract YuzuUSDTest_Issuer is YuzuProtoTest_Issuer {
    function _deploy() internal override returns (address) {
        return address(new YuzuUSD());
    }
}

contract YuzuUSDTest_OrderBook is YuzuProtoTest_OrderBook {
    function _deploy() internal override returns (address) {
        return address(new YuzuUSD());
    }
}

contract YuzuUSDInvariantTest is YuzuProtoInvariantTest {
    function _deploy() internal override returns (address) {
        return address(new YuzuUSD());
    }
}
