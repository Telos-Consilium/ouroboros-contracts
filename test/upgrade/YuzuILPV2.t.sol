// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {YuzuILPV2} from "../../src/YuzuILPV2.sol";
import {IYuzuILP, IYuzuILPV2} from "../../src/interfaces/IYuzuILP.sol";

contract YuzuILPUpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function test_ForkUpgrade() public {
        // Skip when RPC_URL is not provided
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        // Skip when YZILP_PROXY_ADDRESS is not provided
        address proxy = vm.envOr("YZILP_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        // Use latest block when YZILP_V1_FORK_BLOCK is not provided or zero
        uint256 forkBlock = vm.envOr("YZILP_V1_FORK_BLOCK", uint256(0));
        uint256 forkId;
        if (forkBlock == 0) {
            emit log("YZILP_V1_FORK_BLOCK not set; forking latest");
            forkId = vm.createFork(rpcUrl);
        } else {
            forkId = vm.createFork(rpcUrl, forkBlock);
        }
        vm.selectFork(forkId);

        // Read baseline state before upgrade
        IYuzuILP baseView = IYuzuILP(proxy);
        uint256 poolSizeBefore = baseView.poolSize();
        uint256 dailyLinearYieldRatePpmBefore = baseView.dailyLinearYieldRatePpm();
        uint256 lastPoolUpdateTimestampBefore = baseView.lastPoolUpdateTimestamp();
        uint256 totalAssetsBefore = baseView.totalAssets();

        address implBefore = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminBefore = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));

        // Deploy new implementation for upgrade
        YuzuILPV2 newImplementation = new YuzuILPV2();

        // Perform the upgrade through the proxy admin
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();
        vm.prank(proxyAdminOwner);
        // Upgrade and initialize V2
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)),
            address(newImplementation),
            abi.encodeWithSelector(YuzuILPV2.initializeV2.selector)
        );

        // Capture post-upgrade slots
        address implAfter = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminAfter = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        assertTrue(implBefore != implAfter, "implementation unchanged");
        assertEq(implAfter, address(newImplementation), "implementation not updated");
        assertEq(adminAfter, adminBefore, "admin drift");

        // Validate storage slots and key invariants after upgrade
        IYuzuILPV2 upgraded = IYuzuILPV2(proxy);
        assertEq(upgraded.poolSize(), poolSizeBefore, "poolSize drift");
        assertEq(upgraded.dailyLinearYieldRatePpm(), dailyLinearYieldRatePpmBefore, "dailyLinearYieldRatePpm drift");
        assertEq(upgraded.lastPoolUpdateTimestamp(), lastPoolUpdateTimestampBefore, "lastPoolUpdateTimestamp drift");
        assertEq(upgraded.totalAssets(), totalAssetsBefore, "totalAssets drift"); // Assuming no time passed/yield accrued in same block

        // Verify V2 initialization
        YuzuILPV2 v2 = YuzuILPV2(address(proxy));
        assertEq(v2.lastDistributionPeriod(), 1, "V2 initialization failed");
    }
}
