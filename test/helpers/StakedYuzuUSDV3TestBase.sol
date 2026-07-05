// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {StakedYuzuUSD} from "../../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3Migration} from "../../src/StakedYuzuUSDV3Migration.sol";
import {StakedYuzuUSDV3RecoveryMigration} from "../../src/StakedYuzuUSDV3RecoveryMigration.sol";
import {StakedYuzuUSDV3} from "../../src/StakedYuzuUSDV3.sol";

abstract contract StakedYuzuUSDV3TestBase is Test {
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal constant LOST_ADDRESS = 0xB3a9009c89a3Fc46314C2df642d920c244C61c06;
    address internal constant RECOVERY_RECEIVER = 0xAFFcbAb01F7C2B3D533198B741C9E32Df2d78616;
    uint256 internal constant RECOVERY_AMOUNT = 2_913_260.544695655463689601 ether;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 internal constant DELAY_EXEMPT_ROLE = keccak256("DELAY_EXEMPT_ROLE");
    bytes32 internal constant REDEEM_FEE_EXEMPT_ROLE = keccak256("REDEEM_FEE_EXEMPT_ROLE");

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

        _upgradeToRecoveryMigration(
            proxyAdmin,
            proxy,
            owner,
            abi.encodeWithSelector(StakedYuzuUSDV3RecoveryMigration.migrateToV3.selector, admin)
        );
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

    function _deploySeededV1Proxy(address proxyOwner)
        internal
        returns (TransparentUpgradeableProxy proxy, ProxyAdmin deployedProxyAdmin, StakedYuzuUSDV3Migration staked)
    {
        proxy = _deployV1Proxy(proxyOwner);
        deployedProxyAdmin = _proxyAdmin(address(proxy));
        staked = StakedYuzuUSDV3Migration(address(proxy));

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

    function _upgradeToMigration(
        ProxyAdmin targetProxyAdmin,
        TransparentUpgradeableProxy proxy,
        address proxyOwner,
        bytes memory data
    ) internal {
        address migrationImpl = address(new StakedYuzuUSDV3Migration());
        vm.prank(proxyOwner);
        targetProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), migrationImpl, data);
    }

    function _upgradeToRecoveryMigration(
        ProxyAdmin targetProxyAdmin,
        TransparentUpgradeableProxy proxy,
        address proxyOwner,
        bytes memory data
    ) internal {
        address migrationImpl = address(new StakedYuzuUSDV3RecoveryMigration());
        vm.prank(proxyOwner);
        targetProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), migrationImpl, data);
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

    function _proxyAdmin(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, _ADMIN_SLOT)))));
    }

    function _approveAssets(address assetOwner, address spender, uint256 amount) internal {
        vm.prank(assetOwner);
        yzusd.approve(spender, amount);
    }
}
