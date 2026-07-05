// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IPSM} from "../../src/interfaces/IPSM.sol";
import {PSMV2} from "../../src/PSMV2.sol";
import {Throttle} from "../../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {ADMIN_ROLE, LIMIT_MANAGER_ROLE, THROTTLE_EXEMPT_ROLE} from "../helpers/TestRoles.sol";

contract PSMV2UpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

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
            ITransparentUpgradeableProxy(payable(proxy)), impl, abi.encodeWithSelector(PSMV2.reinitializeV2.selector)
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

        vm.expectRevert();
        v2.reinitializeV2();
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }

    function _admin(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
    }
}
