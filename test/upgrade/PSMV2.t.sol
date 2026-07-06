// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {IPSM} from "../../src/interfaces/IPSM.sol";
import {PSMV2} from "../../src/PSMV2.sol";
import {Throttle} from "../../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {ADMIN_ROLE, LIMIT_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "../helpers/TestRoles.sol";
import {UpgradeTestBase} from "../helpers/UpgradeTestBase.sol";

contract PSMV2UpgradeForkTest is UpgradeTestBase {
    function test_ForkUpgrade() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        address proxy = vm.envOr("PSM_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        uint256 forkBlock = vm.envOr("PSM_V1_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, forkBlock);
        vm.selectFork(forkId);

        IPSM psm = IPSM(proxy);
        address implBefore = _implementation(proxy);
        address adminBefore = _admin(proxy);
        address proxyAdminOwner = ProxyAdmin(adminBefore).owner();

        address assetBefore = psm.asset();
        address vault0Before = psm.vault0();
        address vault1Before = psm.vault1();
        uint256 minRedeemOrderBefore = PSMV2(proxy).minRedeemOrder();
        uint256 orderCountBefore = psm.orderCount();
        uint256 pendingOrderCountBefore = psm.pendingOrderCount();
        uint256 liquidityBefore = psm.liquidity();

        address impl = address(new PSMV2());
        vm.prank(proxyAdminOwner);
        ProxyAdmin(adminBefore).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)), impl, abi.encodeWithSelector(PSMV2.reinitialize.selector)
        );

        assertTrue(implBefore != _implementation(proxy), "implementation unchanged");
        assertEq(_implementation(proxy), impl, "implementation not updated");
        assertEq(_admin(proxy), adminBefore, "admin drift");

        PSMV2 v2 = PSMV2(proxy);
        assertEq(v2.asset(), assetBefore, "asset drift");
        assertEq(v2.vault0(), vault0Before, "vault0 drift");
        assertEq(v2.vault1(), vault1Before, "vault1 drift");
        assertEq(v2.minRedeemOrder(), minRedeemOrderBefore, "minRedeemOrder drift");
        assertEq(v2.orderCount(), orderCountBefore, "orderCount drift");
        assertEq(v2.pendingOrderCount(), pendingOrderCountBefore, "pendingOrderCount drift");
        assertEq(v2.liquidity(), liquidityBefore, "liquidity drift");

        assertEq(v2.getRoleAdmin(LIMIT_MANAGER_ROLE), ADMIN_ROLE, "LIMIT_MANAGER_ROLE admin");
        assertEq(v2.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "THROTTLE_EXEMPT_ROLE admin");

        Throttle memory mintThrottle = v2.getMintThrottle();
        Throttle memory redeemThrottle = v2.getRedeemThrottle();
        assertEq(mintThrottle.blockLimit, type(uint256).max, "mint block limit");
        assertEq(mintThrottle.dailyLimit, type(uint256).max, "mint daily limit");
        assertEq(redeemThrottle.blockLimit, type(uint256).max, "redeem block limit");
        assertEq(redeemThrottle.dailyLimit, type(uint256).max, "redeem daily limit");

        v2.maxDeposit(address(this));
        v2.maxRedeem(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), LIMIT_MANAGER_ROLE
            )
        );
        v2.setMintThrottle(1, 1);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.reinitialize();
    }
}
