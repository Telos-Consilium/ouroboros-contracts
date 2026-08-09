// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSD} from "../../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3Recovery} from "../../src/StakedYuzuUSDV3Recovery.sol";
import {StakedYuzuUSDV3} from "../../src/StakedYuzuUSDV3.sol";
import {LOST_ADDRESS, RECOVERY_AMOUNT, RECOVERY_RECEIVER} from "./RecoveryConstants.sol";
import {
    ADMIN_ROLE,
    DELAY_EXEMPT_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    PAUSE_MANAGER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    REDEEM_MANAGER_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "./TestRoles.sol";
import {UpgradeTestBase} from "./UpgradeTestBase.sol";

abstract contract StakedYuzuUSDV3TestBase is UpgradeTestBase {
    StakedYuzuUSDV3 public styz3;
    ProxyAdmin public proxyAdmin;
    ERC20Mock public yzusd;

    address public owner;
    address public feeReceiver;
    address public user1;
    address public user2;
    address public admin;
    address public pauseManager;

    function _setUpStakedYuzuUSDV3() internal {
        _setUpActors();
        _setUpAsset();

        (TransparentUpgradeableProxy proxy, ProxyAdmin deployedProxyAdmin,) = _deploySeededV1Proxy(owner);
        proxyAdmin = deployedProxyAdmin;

        _upgradeToRecovery(proxyAdmin, proxy, owner);
        _upgradeToParkedV3(proxyAdmin, proxy, owner, admin);

        styz3 = StakedYuzuUSDV3(address(proxy));
        vm.prank(admin);
        styz3.grantRole(PAUSE_MANAGER_ROLE, pauseManager);

        vm.prank(pauseManager);
        styz3.unpause();

        _approveAssets(owner, address(styz3), type(uint256).max);
        _approveAssets(user1, address(styz3), type(uint256).max);
        _approveAssets(user2, address(styz3), type(uint256).max);
    }

    function _setUpActors() internal {
        owner = makeAddr("owner");
        feeReceiver = makeAddr("feeReceiver");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        admin = makeAddr("admin");
        pauseManager = makeAddr("pauseManager");
    }

    function _setUpAsset() internal {
        yzusd = new ERC20Mock();
        yzusd.mint(owner, 10_000_000e18);
        yzusd.mint(user1, 10_000_000e18);
        yzusd.mint(user2, 10_000_000e18);
    }

    /// @dev A fresh V3 vault with zero supply, skipping recovery, for empty-vault inflation tests.
    function _deployFreshEmptyV3() internal returns (StakedYuzuUSDV3 fresh) {
        TransparentUpgradeableProxy proxy = _deployV1Proxy(owner);
        ProxyAdmin freshProxyAdmin = _proxyAdmin(address(proxy));

        vm.prank(owner);
        StakedYuzuUSD(address(proxy)).pause();

        _upgradeToParkedV3(freshProxyAdmin, proxy, owner, admin);

        fresh = StakedYuzuUSDV3(address(proxy));
        vm.prank(admin);
        fresh.grantRole(PAUSE_MANAGER_ROLE, pauseManager);
        vm.prank(pauseManager);
        fresh.unpause();

        _approveAssets(user1, address(fresh), type(uint256).max);
        _approveAssets(user2, address(fresh), type(uint256).max);
    }

    function _deploySeededV1Proxy(address proxyOwner)
        internal
        returns (TransparentUpgradeableProxy proxy, ProxyAdmin deployedProxyAdmin, StakedYuzuUSD staked)
    {
        proxy = _deployV1Proxy(proxyOwner);
        deployedProxyAdmin = _proxyAdmin(address(proxy));
        staked = StakedYuzuUSD(address(proxy));

        _approveAssets(user1, address(staked), type(uint256).max);
        vm.prank(user1);
        staked.deposit(RECOVERY_AMOUNT, LOST_ADDRESS);

        vm.prank(proxyOwner);
        staked.pause();
    }

    function _deployV1Proxy(address proxyOwner) internal returns (TransparentUpgradeableProxy) {
        address v1Impl = address(new StakedYuzuUSD());
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            proxyOwner,
            feeReceiver,
            1 days
        );
        return new TransparentUpgradeableProxy(v1Impl, proxyOwner, initData);
    }

    function _upgradeToRecovery(ProxyAdmin targetProxyAdmin, TransparentUpgradeableProxy proxy, address proxyOwner)
        internal
    {
        address recoveryImpl = address(new StakedYuzuUSDV3Recovery());
        vm.prank(proxyOwner);
        targetProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            recoveryImpl,
            abi.encodeWithSelector(StakedYuzuUSDV3Recovery.recover.selector)
        );
    }

    function _upgradeToParkedV3(
        ProxyAdmin targetProxyAdmin,
        TransparentUpgradeableProxy proxy,
        address proxyOwner,
        address v3Admin
    ) internal {
        address v3Impl = _deploy();
        bytes memory reinitData = abi.encodeWithSelector(StakedYuzuUSDV3.reinitialize.selector, v3Admin);
        vm.prank(proxyOwner);
        targetProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), v3Impl, reinitData);
    }

    function _deploy() internal virtual returns (address) {
        return address(new StakedYuzuUSDV3());
    }

    function _approveAssets(address assetOwner, address spender, uint256 amount) internal {
        vm.prank(assetOwner);
        yzusd.approve(spender, amount);
    }
}
