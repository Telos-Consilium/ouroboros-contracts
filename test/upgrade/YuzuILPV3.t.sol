// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuILPV3} from "../../src/YuzuILPV3.sol";
import {YuzuILPV3Facet} from "../../src/YuzuILPV3Facet.sol";
import {IYuzuILPV2} from "../../src/interfaces/IYuzuILP.sol";
import {Throttle} from "../../src/interfaces/proto/IYuzuThrottleDefinitions.sol";

contract YuzuILPV3UpgradeForkTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 private constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    function test_ForkUpgrade() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        address proxy = vm.envOr("YZILP_PROXY_ADDRESS", address(0));
        if (proxy == address(0)) {
            vm.skip(true);
            return;
        }

        uint256 forkBlock = vm.envOr("YZILP_V2_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpcUrl) : vm.createFork(rpcUrl, forkBlock);
        vm.selectFork(forkId);

        IYuzuILPV2 v2 = IYuzuILPV2(proxy);
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
        uint256 poolSizeBefore = v2.poolSize();
        uint256 dailyYieldBefore = v2.dailyLinearYieldRatePpm();
        uint256 lastPoolUpdateBefore = v2.lastPoolUpdateTimestamp();
        uint256 lastDistributedAmountBefore = v2.lastDistributedAmount();
        uint256 lastDistributionPeriodBefore = v2.lastDistributionPeriod();
        uint256 lastDistributionTimestampBefore = v2.lastDistributionTimestamp();
        uint256 orderCountBefore = v2.orderCount();

        address facet = address(new YuzuILPV3Facet());
        address impl = address(new YuzuILPV3(facet));
        vm.prank(proxyAdminOwner);
        ProxyAdmin(adminBefore).upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)),
            impl,
            abi.encodeWithSelector(YuzuILPV3.reinitializeV3.selector)
        );

        assertTrue(implBefore != _implementation(proxy), "implementation unchanged");
        assertEq(_implementation(proxy), impl, "implementation not updated");
        assertEq(_admin(proxy), adminBefore, "admin drift");

        YuzuILPV3 v3 = YuzuILPV3(proxy);
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
        assertEq(v3.poolSize(), poolSizeBefore, "poolSize drift");
        assertEq(v3.dailyLinearYieldRatePpm(), dailyYieldBefore, "daily yield drift");
        assertEq(v3.lastPoolUpdateTimestamp(), lastPoolUpdateBefore, "lastPoolUpdateTimestamp drift");
        assertEq(v3.lastDistributedAmount(), lastDistributedAmountBefore, "lastDistributedAmount drift");
        assertEq(v3.lastDistributionPeriod(), lastDistributionPeriodBefore, "lastDistributionPeriod drift");
        assertEq(v3.lastDistributionTimestamp(), lastDistributionTimestampBefore, "lastDistributionTimestamp drift");
        assertEq(v3.orderCount(), orderCountBefore, "orderCount drift");

        assertEq(v3.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "THROTTLE_EXEMPT_ROLE admin");
        assertEq(v3.getRoleAdmin(FEE_MANAGER_ROLE), ADMIN_ROLE, "FEE_MANAGER_ROLE admin");
        assertEq(v3.mintFeePpm(), 0, "mintFeePpm");
        assertEq(v3.managementFeeRatePpm(), 0, "managementFeeRatePpm");
        assertEq(v3.pendingManagementFeeRatePpm(), 0, "pendingManagementFeeRatePpm");
        assertEq(v3.performanceFeeRatePpm(), 0, "performanceFeeRatePpm");
        assertEq(v3.pendingPerformanceFeeRatePpm(), 0, "pendingPerformanceFeeRatePpm");

        Throttle memory mintThrottle = v3.getMintThrottle();
        assertEq(mintThrottle.blockLimit, type(uint256).max, "mint block limit");
        assertEq(mintThrottle.dailyLimit, type(uint256).max, "mint daily limit");

        v3.maxDeposit(address(this));
        v3.maxMint(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), LIMIT_MANAGER_ROLE
            )
        );
        v3.setMintThrottle(1, 1);

        vm.expectRevert();
        v3.reinitializeV3();
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }

    function _admin(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT))));
    }
}
