// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {YuzuUSDV2} from "../../src/YuzuUSDV2.sol";
import {IYuzuUSD, IYuzuUSDV2} from "../../src/interfaces/IYuzuUSD.sol";
import {ADMIN_ROLE, BURNER_ROLE} from "../helpers/TestRoles.sol";
import {UpgradeTestBase} from "../helpers/UpgradeTestBase.sol";

contract YuzuUSDUpgradeForkTest is UpgradeTestBase {
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
        address implBefore = _implementation(proxy);
        address adminBefore = _admin(proxy);
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
        address proxyAdmin = _admin(proxy);
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();
        vm.prank(proxyAdminOwner);
        // Upgrade and initialize V2
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), address(newImplementation), bytes("")
        );

        // Capture post-upgrade slots
        address implAfter = _implementation(proxy);
        address adminAfter = _admin(proxy);
        assertTrue(implBefore != implAfter, "implementation unchanged");
        assertEq(implAfter, address(newImplementation), "implementation not updated");
        assertEq(adminAfter, adminBefore, "admin drift");

        // Validate storage slots and key invariants after upgrade
        IYuzuUSDV2 upgraded = IYuzuUSDV2(proxy);
        assertEq(upgraded.asset(), assetBefore, "asset drift");
        assertEq(upgraded.treasury(), treasuryBefore, "treasury drift");
        assertEq(upgraded.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(upgraded.redeemOrderFeePpm(), redeemOrderFeePpmBefore, "redeemOrderFeePpm drift");
        assertEq(upgraded.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(upgraded.isMintRestricted(), isMintRestrictedBefore, "isMintRestricted drift");
        assertEq(upgraded.isRedeemRestricted(), isRedeemRestrictedBefore, "isRedeemRestricted drift");

        // Verify BURNER_ROLE admin is not set before reinitialize
        assertEq(
            IAccessControl(proxy).getRoleAdmin(BURNER_ROLE),
            bytes32(0),
            "BURNER_ROLE admin should be unset before reinit"
        );

        // Call reinitialize to set up V2 state
        YuzuUSDV2(proxy).reinitialize();

        // Verify BURNER_ROLE admin is now ADMIN_ROLE
        assertEq(IAccessControl(proxy).getRoleAdmin(BURNER_ROLE), ADMIN_ROLE, "BURNER_ROLE admin not set after reinit");

        // Verify reinitialize cannot be called again
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        YuzuUSDV2(proxy).reinitialize();
    }
}
