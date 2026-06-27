// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../src/YuzuUSDV3Facet.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV2} from "../src/YuzuILPV2.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {YuzuILPV3Facet} from "../src/YuzuILPV3Facet.sol";
import {Throttle} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";

contract YuzuV3UpgradeAssetMock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuV3UpgradeTest is Test {
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 private constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    address private owner = makeAddr("owner");
    address private admin = makeAddr("admin");
    address private treasury = makeAddr("treasury");
    address private feeReceiver = makeAddr("feeReceiver");
    address private limitManager = makeAddr("limitManager");

    function test_YuzuUSD_UpgradesToFacetedV3() public {
        YuzuV3UpgradeAssetMock asset = new YuzuV3UpgradeAssetMock();
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(new YuzuUSD()), owner, _initData(address(asset)));
        YuzuUSD yzusd = YuzuUSD(address(proxy));

        address assetBefore = yzusd.asset();
        address treasuryBefore = yzusd.treasury();
        address feeReceiverBefore = yzusd.feeReceiver();

        ProxyAdmin proxyAdmin = _proxyAdmin(address(proxy));
        address v2Impl = address(new YuzuUSDV2());
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v2Impl,
            abi.encodeWithSelector(YuzuUSDV2.reinitialize.selector)
        );

        address v3Impl = address(new YuzuUSDV3(address(new YuzuUSDV3Facet())));
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v3Impl,
            abi.encodeWithSelector(YuzuUSDV3.reinitializeV3.selector)
        );

        YuzuUSDV3 v3 = YuzuUSDV3(address(proxy));
        assertEq(_implementation(address(proxy)), v3Impl, "implementation");
        assertEq(v3.asset(), assetBefore, "asset");
        assertEq(v3.treasury(), treasuryBefore, "treasury");
        assertEq(v3.feeReceiver(), feeReceiverBefore, "feeReceiver");
        assertEq(IAccessControl(address(proxy)).getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "throttle admin");

        vm.prank(admin);
        v3.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        vm.prank(limitManager);
        v3.setMintThrottle(100e6, 1_000e6);

        Throttle memory throttle = v3.getMintThrottle();
        assertEq(throttle.blockLimit, 100e6, "block limit");
        assertEq(throttle.dailyLimit, 1_000e6, "daily limit");
    }

    function test_YuzuILP_UpgradesToFacetedV3() public {
        YuzuV3UpgradeAssetMock asset = new YuzuV3UpgradeAssetMock();
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(new YuzuILP()), owner, _initData(address(asset)));
        YuzuILP yzilp = YuzuILP(address(proxy));

        address assetBefore = yzilp.asset();
        address treasuryBefore = yzilp.treasury();
        address feeReceiverBefore = yzilp.feeReceiver();
        uint256 poolSizeBefore = yzilp.poolSize();

        ProxyAdmin proxyAdmin = _proxyAdmin(address(proxy));
        address v2Impl = address(new YuzuILPV2());
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v2Impl,
            abi.encodeWithSelector(YuzuILPV2.reinitialize.selector)
        );

        address v3Impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v3Impl,
            abi.encodeWithSelector(YuzuILPV3.reinitializeV3.selector)
        );

        YuzuILPV3 v3 = YuzuILPV3(address(proxy));
        assertEq(_implementation(address(proxy)), v3Impl, "implementation");
        assertEq(v3.asset(), assetBefore, "asset");
        assertEq(v3.treasury(), treasuryBefore, "treasury");
        assertEq(v3.feeReceiver(), feeReceiverBefore, "feeReceiver");
        assertEq(v3.poolSize(), poolSizeBefore, "poolSize");
        assertEq(IAccessControl(address(proxy)).getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE, "throttle admin");
        assertEq(IAccessControl(address(proxy)).getRoleAdmin(FEE_MANAGER_ROLE), ADMIN_ROLE, "fee admin");

        vm.prank(admin);
        v3.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        vm.prank(limitManager);
        v3.setMintThrottle(100e6, 1_000e6);

        Throttle memory throttle = v3.getMintThrottle();
        assertEq(throttle.blockLimit, 100e6, "block limit");
        assertEq(throttle.dailyLimit, 1_000e6, "daily limit");
    }

    function _initData(address asset) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            asset,
            "Token",
            "TKN",
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
    }

    function _proxyAdmin(address proxy) private view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT)))));
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }
}
