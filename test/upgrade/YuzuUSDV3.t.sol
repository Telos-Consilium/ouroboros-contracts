// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {YuzuUSDV3} from "../../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../../src/YuzuUSDV3Facet.sol";
import {IYuzuUSDV2} from "../../src/interfaces/IYuzuUSD.sol";
import {Throttle} from "../../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {ADMIN_ROLE, LIMIT_MANAGER_ROLE, NAV_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "../helpers/TestRoles.sol";
import {UpgradeTestBase} from "../helpers/UpgradeTestBase.sol";

contract YuzuUSDV3UpgradeForkTest is UpgradeTestBase {
    function test_ForkUpgrade() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        address proxy = vm.envOr("YZUSD_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        uint256 forkBlock = vm.envOr("YZUSD_V2_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, forkBlock);
        vm.selectFork(forkId);

        IYuzuUSDV2 v2 = IYuzuUSDV2(proxy);
        address implBefore = _implementation(proxy);
        address adminBefore = _admin(proxy);
        address proxyAdminOwner = ProxyAdmin(adminBefore).owner();

        address assetBefore = v2.asset();
        address treasuryBefore = v2.treasury();
        uint256 capBefore = v2.cap();
        uint256 liquidityBufferBefore = v2.liquidityBufferSize();
        uint256 fillWindowBefore = v2.fillWindow();
        uint256 minRedeemOrderBefore = v2.minRedeemOrder();
        uint256 redeemFeePpmBefore = v2.redeemFeePpm();
        uint256 redeemOrderFeePpmBefore = v2.redeemOrderFeePpm();
        address feeReceiverBefore = v2.feeReceiver();
        bool isMintRestrictedBefore = v2.isMintRestricted();
        bool isRedeemRestrictedBefore = v2.isRedeemRestricted();
        uint256 orderCountBefore = v2.orderCount();

        address facet = address(new YuzuUSDV3Facet());
        address impl = address(new YuzuUSDV3(facet));
        vm.prank(proxyAdminOwner);
        ProxyAdmin(adminBefore).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), impl, abi.encodeWithSelector(YuzuUSDV3.reinitialize.selector)
        );

        assertTrue(implBefore != _implementation(proxy), "implementation unchanged");
        assertEq(_implementation(proxy), impl, "implementation not updated");
        assertEq(_admin(proxy), adminBefore, "admin drift");

        YuzuUSDV3 v3 = YuzuUSDV3(proxy);
        assertEq(v3.asset(), assetBefore, "asset drift");
        assertEq(v3.treasury(), treasuryBefore, "treasury drift");
        assertEq(v3.cap(), capBefore, "cap drift");
        assertEq(v3.liquidityBufferSize(), liquidityBufferBefore, "liquidity buffer drift");
        assertEq(v3.fillWindow(), fillWindowBefore, "fillWindow drift");
        assertEq(v3.minRedeemOrder(), minRedeemOrderBefore, "minRedeemOrder drift");
        assertEq(v3.redeemFeePpm(), redeemFeePpmBefore, "redeemFeePpm drift");
        assertEq(v3.redeemOrderFeePpm(), redeemOrderFeePpmBefore, "redeemOrderFeePpm drift");
        assertEq(v3.feeReceiver(), feeReceiverBefore, "feeReceiver drift");
        assertEq(v3.isMintRestricted(), isMintRestrictedBefore, "isMintRestricted drift");
        assertEq(v3.isRedeemRestricted(), isRedeemRestrictedBefore, "isRedeemRestricted drift");
        assertEq(v3.orderCount(), orderCountBefore, "orderCount drift");

        assertEq(v3.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "THROTTLE_EXEMPT_ROLE admin");
        assertEq(v3.getRoleAdmin(NAV_MANAGER_ROLE), ADMIN_ROLE, "NAV_MANAGER_ROLE admin");
        assertEq(v3.nav(), 1e18, "nav");

        Throttle memory mintThrottle = v3.getMintThrottle();
        Throttle memory redeemThrottle = v3.getRedeemThrottle();
        assertEq(mintThrottle.blockLimit, type(uint256).max, "mint block limit");
        assertEq(mintThrottle.dailyLimit, type(uint256).max, "mint daily limit");
        assertEq(redeemThrottle.blockLimit, type(uint256).max, "redeem block limit");
        assertEq(redeemThrottle.dailyLimit, type(uint256).max, "redeem daily limit");

        v3.maxDeposit(address(this));
        v3.maxWithdraw(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), LIMIT_MANAGER_ROLE
            )
        );
        v3.setMintThrottle(1, 1);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v3.reinitialize();
    }
}
