// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {YuzuUSDV2} from "../../src/YuzuUSDV2.sol";
import {IYuzuUSD} from "../../src/interfaces/IYuzuUSD.sol";

contract YuzuUSDUpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function test_ForkUpgrade() public {
        // Skip when RPC_URL is not provided
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        // Skip when YZUSD_PROXY_ADDRESS is not provided
        address proxy = vm.envOr("YZUSD_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        // Use latest block when YZUSD_V1_FORK_BLOCK is not provided or zero
        uint256 forkBlock = vm.envOr("YZUSD_V1_FORK_BLOCK", uint256(0));
        uint256 forkId;
        if (forkBlock == 0) {
            emit log("YZUSD_V1_FORK_BLOCK not set; forking latest");
            forkId = vm.createFork(rpcUrl);
        } else {
            forkId = vm.createFork(rpcUrl, forkBlock);
        }
        vm.selectFork(forkId);

        // Read baseline state before upgrade
        IYuzuUSD baseView = IYuzuUSD(proxy);
        address implBefore = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminBefore = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address assetBefore = baseView.asset();
        address treasuryBefore = baseView.treasury();
        uint256 redeemFeePpmBefore = baseView.redeemFeePpm();
        uint256 redeemOrderFeePpmBefore = baseView.redeemOrderFeePpm();
        address feeReceiverBefore = baseView.feeReceiver();
        bool isMintRestrictedBefore = baseView.isMintRestricted();
        bool isRedeemRestrictedBefore = baseView.isRedeemRestricted();

        // Deploy new implementation for upgrade
        YuzuUSDV2 newImplementation = new YuzuUSDV2();

        // Perform the upgrade through the proxy admin
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();
        vm.prank(proxyAdminOwner);
        // Upgrade and initialize V2
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), address(newImplementation), bytes("")
        );

        // Capture post-upgrade slots
        address implAfter = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminAfter = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        assertTrue(implBefore != implAfter, "implementation unchanged");
        assertEq(implAfter, address(newImplementation), "implementation not updated");
        assertEq(adminAfter, adminBefore, "admin drift");

        // Validate storage slots and key invariants after upgrade
        IYuzuUSD upgraded = IYuzuUSD(proxy);
        assertEq(upgraded.asset(), assetBefore, "asset drift");
        assertEq(upgraded.treasury(), treasuryBefore, "treasury drift");
        assertEq(upgraded.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(upgraded.redeemOrderFeePpm(), redeemOrderFeePpmBefore, "redeemOrderFeePpm drift");
        assertEq(upgraded.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(upgraded.isMintRestricted(), isMintRestrictedBefore, "isMintRestricted drift");
        assertEq(upgraded.isRedeemRestricted(), isRedeemRestrictedBefore, "isRedeemRestricted drift");
    }
}
