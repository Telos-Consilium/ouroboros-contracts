// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

contract ComputeStorageLocation is Script {
    function run() public {
        string memory namespace = vm.envString("NAMESPACE");
        bytes32 storageLocation = keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
        console.logBytes32(storageLocation);
    }
}
