// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";

import {YuzuProtoTest} from "./YuzuProto.t.sol";
import {YuzuProtoV2Test_Common, YuzuProtoV2Test_Issuer, YuzuProtoV2Test_OrderBook} from "./YuzuProtoV2.t.sol";
import {YuzuUSDTest_Common, YuzuUSDTest_Issuer, YuzuUSDTest_OrderBook} from "./YuzuUSD.t.sol";

contract YuzuUSDV2Test_Common is YuzuUSDTest_Common, YuzuProtoV2Test_Common {
    function _deploy() internal override(YuzuProtoTest, YuzuUSDTest_Common) returns (address) {
        return address(new YuzuUSDV2());
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
