// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSDV2} from "../../src/StakedYuzuUSDV2.sol";
import {IStakedYuzuUSD} from "../../src/interfaces/IStakedYuzuUSD.sol";
import {IStakedYuzuUSDV2, IntegrationConfig} from "../../src/interfaces/IStakedYuzuUSD.sol";

interface IOwnable {
    function owner() external returns (address);
}

contract StakedYuzuUSDUpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    function test_ForkUpgrade() public {
        // Skip when RPC_URL is not provided
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        // Skip when SYZUSD_PROXY_ADDRESS is not provided
        address proxy = vm.envOr("SYZUSD_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        // Use latest block when SYZUSD_V1_FORK_BLOCK is not provided or zero
        uint256 forkBlock = vm.envOr("SYZUSD_V1_FORK_BLOCK", uint256(0));
        uint256 forkId;
        if (forkBlock == 0) {
            emit log("SYZUSD_V1_FORK_BLOCK not set; forking latest");
            forkId = vm.createFork(rpcUrl);
        } else {
            forkId = vm.createFork(rpcUrl, forkBlock);
        }
        vm.selectFork(forkId);

        // Read baseline state before upgrade
        IStakedYuzuUSD baseView = IStakedYuzuUSD(proxy);
        address owner = IOwnable(address(baseView)).owner();
        address implBefore = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        address adminBefore = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        uint256 redeemDelayBefore = baseView.redeemDelay();
        uint256 redeemFeePpmBefore = baseView.redeemFeePpm();
        address feeReceiverBefore = baseView.feeReceiver();
        uint256 lastDistributedAmountBefore = baseView.lastDistributedAmount();
        uint256 lastDistributionPeriodBefore = baseView.lastDistributionPeriod();
        uint256 lastDistributionTimeBefore = baseView.lastDistributionTime();
        uint256 totalPendingOrderValueBefore = baseView.totalPendingOrderValue();
        uint256 orderCountBefore = baseView.orderCount();
        string memory nameBefore = baseView.name();
        string memory symbolBefore = baseView.symbol();

        // Deploy new implementation for upgrade
        StakedYuzuUSDV2 newImplementation = new StakedYuzuUSDV2();

        // Perform the upgrade through the proxy admin
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();
        vm.prank(proxyAdminOwner);
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
        IStakedYuzuUSDV2 upgraded = IStakedYuzuUSDV2(proxy);
        assertEq(upgraded.redeemDelay(), redeemDelayBefore, "redeemDelay drift");
        assertEq(upgraded.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(upgraded.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(upgraded.lastDistributedAmount(), lastDistributedAmountBefore, "lastDistributedAmount drift");
        assertEq(upgraded.lastDistributionPeriod(), lastDistributionPeriodBefore, "lastDistributionPeriod drift");
        assertEq(upgraded.lastDistributionTime(), lastDistributionTimeBefore, "lastDistributionTime drift");
        assertEq(upgraded.lastDistributionTimestamp(), lastDistributionTimeBefore, "lastDistributionTimestamp drift");
        assertEq(upgraded.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift");
        assertEq(upgraded.orderCount(), orderCountBefore, "orderCount drift");
        assertEq(upgraded.name(), nameBefore, "name drift");
        assertEq(upgraded.symbol(), symbolBefore, "symbol drift");

        // Exercise a V2-only code path to ensure the new logic is active
        address integration = makeAddr("forkIntegration");
        vm.prank(owner);
        upgraded.setIntegration(integration, true, true);
        IntegrationConfig memory cfg = upgraded.getIntegration(integration);
        assertTrue(cfg.canSkipRedeemDelay, "skip flag");
        assertTrue(cfg.waiveRedeemFee, "waive flag");
    }
}
