// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSDV3Recovery} from "../../src/StakedYuzuUSDV3Recovery.sol";
import {StakedYuzuUSDV3} from "../../src/StakedYuzuUSDV3.sol";
import {IStakedYuzuUSD, IStakedYuzuUSDV2} from "../../src/interfaces/IStakedYuzuUSD.sol";
import {IStakedYuzuUSDV3Definitions} from "../../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {ADMIN_ROLE, PAUSE_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "../helpers/TestRoles.sol";

interface IOwnable {
    function owner() external view returns (address);
}

contract StakedYuzuUSDV3UpgradeForkTest is Test, IStakedYuzuUSDV3Definitions {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address constant LOST_ADDRESS = 0xB3a9009c89a3Fc46314C2df642d920c244C61c06;
    address constant RECOVERY_RECEIVER = 0xAFFcbAb01F7C2B3D533198B741C9E32Df2d78616;
    uint256 constant RECOVERY_AMOUNT = 2_913_260.544695655463689601 ether;

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
        // The lost wallet must hold exactly the hardcoded recovery amount on live state so the
        // migration burn zeroes it and the receiver is credited the exact locked balance.
        assertEq(IERC20(proxy).balanceOf(LOST_ADDRESS), RECOVERY_AMOUNT, "lost wallet balance != RECOVERY_AMOUNT");

        vm.prank(v2Owner);
        v2.pause();

        // Upgrade V2 -> recovery atomically via ProxyAdmin.upgradeAndCall
        address recoveryImpl = address(new StakedYuzuUSDV3Recovery());
        address admin = makeAddr("v3Admin");
        bytes memory recoveryData = abi.encodeWithSelector(StakedYuzuUSDV3Recovery.recover.selector);
        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), recoveryImpl, recoveryData);

        address implAfterRecovery = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        assertEq(implAfterRecovery, recoveryImpl, "recovery impl not active");

        StakedYuzuUSDV3Recovery rec = StakedYuzuUSDV3Recovery(proxy);

        // V2 state preserved
        assertEq(rec.redeemDelay(), redeemDelayBefore, "redeemDelay drift");
        assertEq(rec.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(rec.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(rec.lastDistributedAmount(), lastDistributedAmountBefore, "lastDistributedAmount drift");
        assertEq(rec.lastDistributionPeriod(), lastDistributionPeriodBefore, "lastDistributionPeriod drift");
        assertEq(rec.lastDistributionTime(), lastDistributionTimeBefore, "lastDistributionTime drift");
        assertEq(rec.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift");
        assertEq(rec.orderCount(), orderCountBefore, "orderCount drift");
        assertEq(rec.name(), nameBefore, "name drift");
        assertEq(rec.symbol(), symbolBefore, "symbol drift");

        // Recovery executed; ownership untouched at this stage
        assertEq(rec.balanceOf(LOST_ADDRESS), 0, "lost balance not burned");
        assertEq(rec.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT, "recovery receiver not credited");
        assertEq(IOwnable(proxy).owner(), v2Owner, "owner drift at recovery stage");

        // recover is one-shot
        vm.prank(proxyAdminOwner);
        vm.expectRevert();
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), recoveryImpl, recoveryData);

        // Upgrade recovery -> parked V3 runtime; reinitialize migrates ownership and configures
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

        // AccessControl migration performed by reinitialize
        assertEq(v3.owner(), admin, "owner not migrated to admin");
        assertTrue(v3.hasRole(v3.DEFAULT_ADMIN_ROLE(), admin), "DEFAULT_ADMIN_ROLE not granted");
        assertTrue(v3.hasRole(ADMIN_ROLE, admin), "ADMIN_ROLE not granted");

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
}
