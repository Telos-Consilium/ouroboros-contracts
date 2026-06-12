// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSDV3Recovery} from "../../src/StakedYuzuUSDV3Recovery.sol";
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

        // Upgrade V2 -> V3Recovery atomically via ProxyAdmin.upgradeAndCall
        address v3RecoveryImpl = address(new StakedYuzuUSDV3Recovery());
        address admin = makeAddr("v3Admin");
        bytes memory reinitData = abi.encodeWithSelector(StakedYuzuUSDV3Recovery.reinitialize.selector, admin);
        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), v3RecoveryImpl, reinitData);

        address implAfterRecovery = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        assertEq(implAfterRecovery, v3RecoveryImpl, "v3Recovery impl not active");

        StakedYuzuUSDV3Recovery v3R = StakedYuzuUSDV3Recovery(proxy);

        // V2 state preserved
        assertEq(v3R.redeemDelay(), redeemDelayBefore, "redeemDelay drift");
        assertEq(v3R.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(v3R.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(v3R.lastDistributedAmount(), lastDistributedAmountBefore, "lastDistributedAmount drift");
        assertEq(v3R.lastDistributionPeriod(), lastDistributionPeriodBefore, "lastDistributionPeriod drift");
        assertEq(v3R.lastDistributionTime(), lastDistributionTimeBefore, "lastDistributionTime drift");
        assertEq(v3R.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift");
        assertEq(v3R.orderCount(), orderCountBefore, "orderCount drift");
        assertEq(v3R.name(), nameBefore, "name drift");
        assertEq(v3R.symbol(), symbolBefore, "symbol drift");

        // Recovery executed
        assertEq(v3R.balanceOf(LOST_ADDRESS), 0, "lost balance not burned");
        assertEq(v3R.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT, "recovery receiver not credited");

        // Public instant redeem enabled at upgrade time
        assertTrue(v3R.isInstantRedeemEnabled(), "isInstantRedeemEnabled not set");

        // AccessControl migration
        assertEq(v3R.owner(), admin, "owner not migrated to admin");
        assertTrue(v3R.hasRole(v3R.DEFAULT_ADMIN_ROLE(), admin), "DEFAULT_ADMIN_ROLE not granted");
        assertTrue(v3R.hasRole(ADMIN_ROLE, admin), "ADMIN_ROLE not granted");

        // reinitialize is one-shot
        vm.prank(proxyAdminOwner);
        vm.expectRevert();
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), v3RecoveryImpl, reinitData);

        // Pause-manager bootstrap and unpause
        address pauseManager = makeAddr("pauseManager");
        vm.prank(admin);
        v3R.grantRole(PAUSE_MANAGER_ROLE, pauseManager);
        vm.prank(pauseManager);
        v3R.unpause();

        // Upgrade V3Recovery -> V3 stripped
        address v3StrippedImpl = address(new StakedYuzuUSDV3());
        vm.prank(proxyAdminOwner);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(payable(proxy)), v3StrippedImpl, bytes(""));

        address implAfterStripped = address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
        assertEq(implAfterStripped, v3StrippedImpl, "v3 stripped impl not active");

        StakedYuzuUSDV3 v3 = StakedYuzuUSDV3(proxy);

        // State preserved through second upgrade
        assertEq(v3.redeemDelay(), redeemDelayBefore, "redeemDelay drift after strip");
        assertEq(v3.feeReceiver(), feeReceiverBefore, "feeReceiver drift after strip");
        assertEq(v3.totalPendingOrderValue(), totalPendingOrderValueBefore, "totalPendingOrderValue drift after strip");
        assertEq(v3.orderCount(), orderCountBefore, "orderCount drift after strip");
        assertEq(v3.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT, "recovery receiver drift after strip");
        assertEq(v3.owner(), admin, "owner drift after strip");
        assertTrue(v3.hasRole(ADMIN_ROLE, admin), "ADMIN_ROLE drift after strip");

        // reinitialize on stripped V3 always reverts
        vm.expectRevert();
        v3.reinitialize(admin);
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
