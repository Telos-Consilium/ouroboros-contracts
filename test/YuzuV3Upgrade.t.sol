// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
import {
    ADMIN_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    POOL_MANAGER_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./helpers/TestRoles.sol";
import {UpgradeTestBase} from "./helpers/UpgradeTestBase.sol";

contract YuzuV3UpgradeAssetMock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuV3UpgradeTest is UpgradeTestBase {
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
            abi.encodeWithSelector(YuzuUSDV3.reinitialize.selector)
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
            abi.encodeWithSelector(YuzuILPV3.reinitialize.selector)
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
        assertEq(v3.highWaterMark(), 1e6, "empty vault seeds the par benchmark");
        assertEq(v3.maxDistributionPpm(), type(uint256).max, "distribution cap starts disabled");
    }

    // Deploys a V1 vault, funds it at par, upgrades to V2 and marks the pool.
    function _deployFundedV2(uint256 markPoolSize) private returns (address proxyAddr) {
        YuzuV3UpgradeAssetMock asset = new YuzuV3UpgradeAssetMock();
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(new YuzuILP()), owner, _initData(address(asset)));
        YuzuILP yzilp = YuzuILP(address(proxy));

        vm.prank(admin);
        yzilp.setIsMintRestricted(false);
        asset.mint(address(this), 1000e6);
        asset.approve(address(proxy), 1000e6);
        yzilp.deposit(1000e6, address(this));

        ProxyAdmin proxyAdmin = _proxyAdmin(address(proxy));
        address v2Impl = address(new YuzuILPV2());
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v2Impl,
            abi.encodeWithSelector(YuzuILPV2.reinitialize.selector)
        );

        vm.startPrank(admin);
        YuzuILPV2(address(proxy)).grantRole(POOL_MANAGER_ROLE, admin);
        YuzuILPV2(address(proxy)).startPoolUpdate();
        YuzuILPV2(address(proxy)).updatePool(1000e6, markPoolSize, 0);
        YuzuILPV2(address(proxy)).endPoolUpdate();
        vm.stopPrank();
        return address(proxy);
    }

    function _upgradeIlpToV3(address proxy) private {
        ProxyAdmin proxyAdmin = _proxyAdmin(proxy);
        address v3Impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(proxy)),
            v3Impl,
            abi.encodeWithSelector(YuzuILPV3.reinitialize.selector)
        );
    }

    // Migration seeds the benchmark at the current price, ceil rounded: V3 performance fees
    // begin at this price, since V2 carries no benchmark to import.
    function test_YuzuILP_MigrationSeedsBenchmarkAtCurrentPriceCeil() public {
        address proxy = _deployFundedV2(1100e6 + 1);
        _upgradeIlpToV3(proxy);
        assertEq(YuzuILPV3(proxy).highWaterMark(), 1_100_001, "seed is not the ceil migration price");
    }

    // A vault migrating with live supply and no value seeds the minimum benchmark instead of
    // blocking the upgrade.
    function test_YuzuILP_MigrationSeedsFloorOfOneOnWreckedVault() public {
        address proxy = _deployFundedV2(0);
        _upgradeIlpToV3(proxy);
        assertEq(YuzuILPV3(proxy).highWaterMark(), 1, "wrecked migration did not seed the floor");
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
}
