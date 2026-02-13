// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuILPV2} from "../../src/YuzuILPV2.sol";
import {IYuzuILP, IYuzuILPV2} from "../../src/interfaces/IYuzuILP.sol";

contract YuzuILPUpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant BURNER_ROLE = keccak256("BURNER_ROLE");

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
        address implBefore = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminBefore = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address assetBefore = baseView.asset();
        address treasuryBefore = baseView.treasury();
        uint256 redeemFeePpmBefore = baseView.redeemFeePpm();
        uint256 redeemOrderFeePpmBefore = baseView.redeemOrderFeePpm();
        address feeReceiverBefore = baseView.feeReceiver();
        bool isMintRestrictedBefore = baseView.isMintRestricted();
        bool isRedeemRestrictedBefore = baseView.isRedeemRestricted();
        uint256 poolSizeBefore = baseView.poolSize();
        uint256 dailyLinearYieldRatePpmBefore = baseView.dailyLinearYieldRatePpm();
        uint256 lastPoolUpdateTimestampBefore = baseView.lastPoolUpdateTimestamp();

        // Deploy new implementation for upgrade
        YuzuILPV2 newImplementation = new YuzuILPV2();

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
        IYuzuILPV2 upgraded = IYuzuILPV2(proxy);
        assertEq(upgraded.asset(), assetBefore, "asset drift");
        assertEq(upgraded.treasury(), treasuryBefore, "treasury drift");
        assertEq(upgraded.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(upgraded.redeemOrderFeePpm(), redeemOrderFeePpmBefore, "redeemOrderFeePpm drift");
        assertEq(upgraded.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(upgraded.isMintRestricted(), isMintRestrictedBefore, "isMintRestricted drift");
        assertEq(upgraded.isRedeemRestricted(), isRedeemRestrictedBefore, "isRedeemRestricted drift");
        assertEq(upgraded.poolSize(), poolSizeBefore, "poolSize drift");
        assertEq(upgraded.dailyLinearYieldRatePpm(), dailyLinearYieldRatePpmBefore, "dailyLinearYieldRatePpm drift");
        assertEq(upgraded.lastPoolUpdateTimestamp(), lastPoolUpdateTimestampBefore, "lastPoolUpdateTimestamp drift");
        assertEq(upgraded.lastDistributedAmount(), 0, "lastDistributedAmount drift");
        assertEq(upgraded.lastDistributionPeriod(), 0, "lastDistributionPeriod drift");
        assertEq(upgraded.lastDistributionPeriod(), 0, "lastDistributionPeriod drift");
        assertEq(upgraded.lastDistributionTimestamp(), 0, "lastDistributionTimestamp drift");

        // Verify BURNER_ROLE admin is not set before reinitialize
        assertEq(
            IAccessControl(proxy).getRoleAdmin(BURNER_ROLE),
            bytes32(0),
            "BURNER_ROLE admin should be unset before reinit"
        );

        // Call reinitialize to set up V2 state
        YuzuILPV2(proxy).reinitialize();

        // Verify BURNER_ROLE admin is now ADMIN_ROLE
        assertEq(IAccessControl(proxy).getRoleAdmin(BURNER_ROLE), ADMIN_ROLE, "BURNER_ROLE admin not set after reinit");

        // Verify reinitialize cannot be called again
        vm.expectRevert();
        YuzuILPV2(proxy).reinitialize();
    }
}
