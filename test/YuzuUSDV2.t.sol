// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";
import {YuzuProtoV2Test_Common, YuzuProtoV2Test_Issuer, YuzuProtoV2Test_OrderBook} from "./YuzuProtoV2.t.sol";
import {YuzuUSDTest_Common, YuzuUSDTest_Issuer, YuzuUSDTest_OrderBook} from "./YuzuUSD.t.sol";

contract YuzuUSDV2Test_Common is YuzuUSDTest_Common, YuzuProtoV2Test_Common {
    YuzuUSDV2 yzusd2;

    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function _deploy() internal override(YuzuProtoTest, YuzuUSDTest_Common) returns (address) {
        return address(new YuzuUSDV2());
    }

    function setUp() public override {
        super.setUp();
        yzusd2 = YuzuUSDV2(address(proto));
        yzusd2.reinitialize();

        vm.prank(admin);
        proto.grantRole(BURNER_ROLE, user1);
    }

    function test_Burn() external {
        uint256 assets = 100e6;
        _deposit(user1, assets);

        uint256 balanceBefore = proto.balanceOf(user1);
        uint256 burnAmount = balanceBefore / 2;

        vm.prank(user1);
        yzusd2.burn(burnAmount);

        assertEq(proto.balanceOf(user1), balanceBefore - burnAmount);
    }

    function test_Burn_Revert_NotBurner() external {
        uint256 assets = 100e6;
        _deposit(user2, assets);

        uint256 burnAmount = proto.balanceOf(user2);

        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, BURNER_ROLE)
        );
        yzusd2.burn(burnAmount);
    }
}

contract YuzuUSDV2Test_Issuer is YuzuUSDTest_Issuer, YuzuProtoV2Test_Issuer {
    function _deploy() internal override(YuzuProtoTest, YuzuUSDTest_Issuer) returns (address) {
        return address(new YuzuUSDV2());
    }
}

contract YuzuUSDV2Test_OrderBook is YuzuUSDTest_OrderBook, YuzuProtoV2Test_OrderBook {
    function _deploy() internal override(YuzuProtoTest, YuzuUSDTest_OrderBook) returns (address) {
        return address(new YuzuUSDV2());
    }
}
