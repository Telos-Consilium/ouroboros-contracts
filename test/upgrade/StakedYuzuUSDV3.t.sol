// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSDV3RecoveryMigration} from "../../src/StakedYuzuUSDV3RecoveryMigration.sol";
import {StakedYuzuUSDV3} from "../../src/StakedYuzuUSDV3.sol";
import {IStakedYuzuUSD, IStakedYuzuUSDV2} from "../../src/interfaces/IStakedYuzuUSD.sol";
import {IStakedYuzuUSDV3Definitions} from "../../src/interfaces/IStakedYuzuUSDDefinitions.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract StakedYuzuUSDV3UpgradeForkTest is Test, IStakedYuzuUSDV3Definitions {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    address constant LOST_ADDRESS = address(0x01);
    address constant RECOVERY_RECEIVER = address(0x02);
    uint256 constant RECOVERY_AMOUNT = 1;

    function test_ForkUpgrade() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        address proxy = vm.envOr("SYZUSD_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        uint256 forkBlock = vm.envOr("SYZUSD_V2_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, forkBlock);
        vm.selectFork(forkId);

        IStakedYuzuUSDV2 v2 = IStakedYuzuUSDV2(proxy);
        address v2Owner = IOwnable(proxy).owner();
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
        address proxyAdminOwner = ProxyAdmin(proxyAdmin).owner();

        uint256 redeemDelayBefore = v2.redeemDelay();
        uint256 redeemFeePpmBefore = v2.redeemFeePpm();
        address feeReceiverBefore = v2.feeReceiver();
        uint256 lastDistributedAmountBefore = v2.lastDistributedAmount();
        uint256 lastDistributionPeriodBefore = v2.lastDistributionPeriod();
        uint256 lastDistributionTimeBefore = v2.lastDistributionTime();
        uint256 totalPendingOrderValueBefore = v2.totalPendingOrderValue();
        uint256 orderCountBefore = v2.orderCount();
        string memory nameBefore = v2.name();
        string memory symbolBefore = v2.symbol();
        address assetAddr = v2.asset();

        _seedLostAddress(proxy, assetAddr);

        vm.prank(v2Owner);
        v2.pause();

        // Upgrade V2 -> recovery migration atomically via ProxyAdmin.upgradeAndCall
        address v3MigrationImpl = address(new StakedYuzuUSDV3RecoveryMigration());
        address admin = makeAddr("v3Admin");
        bytes memory migrationData =
            abi.encodeWithSelector(StakedYuzuUSDV3RecoveryMigration.reinitialize.selector, admin);
        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), v3MigrationImpl, migrationData
        );

        address implAfterRecovery = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        assertEq(implAfterRecovery, v3MigrationImpl, "v3Migration impl not active");

        StakedYuzuUSDV3RecoveryMigration v3M = StakedYuzuUSDV3RecoveryMigration(proxy);

        // V2 state preserved
        assertEq(v3M.redeemDelay(), redeemDelayBefore, "redeemDelay drift");
        assertEq(v3M.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(v3M.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(v3M.lastDistributedAmount(), lastDistributedAmountBefore, "lastDistributedAmount drift");
        assertEq(v3M.lastDistributionPeriod(), lastDistributionPeriodBefore, "lastDistributionPeriod drift");
        assertEq(v3M.lastDistributionTime(), lastDistributionTimeBefore, "lastDistributionTime drift");
        assertEq(v3M.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift");
        assertEq(v3M.orderCount(), orderCountBefore, "orderCount drift");
        assertEq(v3M.name(), nameBefore, "name drift");
        assertEq(v3M.symbol(), symbolBefore, "symbol drift");

        // Recovery executed
        assertEq(v3M.balanceOf(LOST_ADDRESS), 0, "lost balance not burned");
        assertEq(v3M.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT, "recovery receiver not credited");

        // AccessControl migration
        assertEq(v3M.owner(), admin, "owner not migrated to admin");
        assertTrue(v3M.hasRole(v3M.DEFAULT_ADMIN_ROLE(), admin), "DEFAULT_ADMIN_ROLE not granted");
        assertTrue(v3M.hasRole(ADMIN_ROLE, admin), "ADMIN_ROLE not granted");

        // reinitialize is one-shot
        vm.prank(proxyAdminOwner);
        vm.expectRevert();
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), v3MigrationImpl, migrationData
        );

        // Upgrade V3Migration -> parked V3 runtime
        address v3Impl = address(new StakedYuzuUSDV3());
        bytes memory parkedData = abi.encodeWithSelector(StakedYuzuUSDV3.reinitialize.selector, admin);
        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), v3Impl, parkedData);

        address implAfterStripped = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        assertEq(implAfterStripped, v3Impl, "v3 impl not active");

        StakedYuzuUSDV3 v3 = StakedYuzuUSDV3(proxy);

        // State preserved through parked upgrade
        assertEq(v3.redeemDelay(), redeemDelayBefore, "redeemDelay drift after strip");
        assertEq(v3.feeReceiver(), feeReceiverBefore, "feeReceiver drift after strip");
        assertEq(v3.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift after strip");
        assertEq(v3.orderCount(), orderCountBefore, "orderCount drift after strip");
        assertEq(v3.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT, "recovery receiver drift after strip");
        assertEq(v3.owner(), admin, "owner drift after strip");
        assertTrue(v3.hasRole(ADMIN_ROLE, admin), "ADMIN_ROLE drift after strip");

        // Public instant redeem starts disabled; integrations can still be enabled explicitly.
        assertFalse(v3.isInstantRedeemEnabled(), "isInstantRedeemEnabled set");

        // Throttles unlimited at parked upgrade time
        assertEq(v3.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "THROTTLE_EXEMPT_ROLE admin not set");
        assertEq(v3.getMintThrottle().blockLimit, type(uint256).max, "mint throttle block limit not max");
        assertEq(v3.getMintThrottle().dailyLimit, type(uint256).max, "mint throttle daily limit not max");
        assertEq(v3.getRedeemThrottle().blockLimit, type(uint256).max, "redeem throttle block limit not max");
        assertEq(v3.getRedeemThrottle().dailyLimit, type(uint256).max, "redeem throttle daily limit not max");

        // Pause-manager bootstrap and unpause
        address pauseManager = makeAddr("pauseManager");
        vm.prank(admin);
        v3.grantRole(PAUSE_MANAGER_ROLE, pauseManager);
        vm.prank(pauseManager);
        v3.unpause();
    }

    function _seedLostAddress(address proxy, address assetAddr) internal {
        uint256 currentBalance = IERC20(proxy).balanceOf(LOST_ADDRESS);
        if (currentBalance >= RECOVERY_AMOUNT) return;

        uint256 needed = RECOVERY_AMOUNT - currentBalance;
        address seeder = makeAddr("seeder");

        uint256 assetsToDeposit = IStakedYuzuUSDV2(proxy).previewMint(needed);
        deal(assetAddr, seeder, assetsToDeposit);

        vm.startPrank(seeder);
        IERC20(assetAddr).approve(proxy, assetsToDeposit);
        IStakedYuzuUSDV2(proxy).mint(needed, LOST_ADDRESS);
        vm.stopPrank();
    }
}
