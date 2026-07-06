// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// @dev ERC-1967 slot reads shared by proxy upgrade tests.
abstract contract UpgradeTestBase is Test {
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }

    function _admin(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
    }

    function _proxyAdmin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(_admin(proxy));
    }
}
