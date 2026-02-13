// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuProtoV2Definitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";

import {YuzuProtoTest_Common, YuzuProtoTest_Issuer, YuzuProtoTest_OrderBook} from "./YuzuProto.t.sol";

abstract contract YuzuProtoV2Test_Common is YuzuProtoTest_Common, IYuzuProtoV2Definitions {}

abstract contract YuzuProtoV2Test_Issuer is YuzuProtoTest_Issuer, IYuzuProtoV2Definitions {}

abstract contract YuzuProtoV2Test_OrderBook is YuzuProtoTest_OrderBook, IYuzuProtoV2Definitions {
    function test_CancelRedeemOrder_ByOrderFiller() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        _cancelRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_CancelRedeemOrder_ByOrderFiller_NotDue() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

        _cancelRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_CancelRedeemOrder_ByOrderFiller_Paused() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

        vm.warp(block.timestamp + proto.fillWindow());

        vm.prank(admin);
        proto.pause();

        _cancelRedeemOrderAndAssert(orderFiller, orderId);
    }

    function test_CancelRedeemOrder_ByOrderFiller_NotDue_Paused() public {
        address controller = user1;
        address owner = user2;
        address receiver = makeAddr("receiver");
        uint256 assets = 100e6;
        uint256 tokens = 100e18;
        _deposit(owner, assets);
        _approveTokens(owner, controller, tokens);
        uint256 orderId = _createRedeemOrder(controller, tokens, receiver, owner);

        vm.prank(admin);
        proto.pause();

        _cancelRedeemOrderAndAssert(orderFiller, orderId);
    }
}
