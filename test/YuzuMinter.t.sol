// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {YuzuMinter} from "../src/YuzuMinter.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";

contract YuzuMinterTest is YuzuProtoTest {
    function _deploy() internal override returns (address) {
        YuzuMinter minter = new YuzuMinter();
        return address(minter);
    }

    // Preview functions
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
}
