// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        YuzuUSD yuzuUSD = new YuzuUSD();
        YuzuILP yuzuILP = new YuzuILP();
        StakedYuzuUSD stakedYuzuUSD = new StakedYuzuUSD();

        console.log("YuzuUSD deployed at        :", address(yuzuUSD));
        console.log("YuzuILP deployed at        :", address(yuzuILP));
        console.log("StakedYuzuUSD deployed at  :", address(stakedYuzuUSD));

        vm.stopBroadcast();
    }
}