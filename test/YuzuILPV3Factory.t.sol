// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {YuzuILPV3Facet} from "../src/YuzuILPV3Facet.sol";
import {YuzuILPV3Factory} from "../src/YuzuILPV3Factory.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuILPV3FactoryTest is YuzuV3TestBase {
    bytes32 internal constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
    bytes32 internal constant SALT = keccak256("yuzu.ilp.v3");

    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    YuzuILPV3Factory internal factory;
    address internal impl;

    address internal root = makeAddr("root");
    address internal deployer = makeAddr("deployer");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");

    function setUp() public {
        asset = _newAsset();
        impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        factory = new YuzuILPV3Factory(root);
        vm.prank(root);
        factory.grantRole(DEPLOYER_ROLE, deployer);
    }

    function _params() internal view returns (YuzuILPV3Factory.InitParams memory) {
        return YuzuILPV3Factory.InitParams({
            asset: address(asset),
            name: "Yuzu ILP",
            symbol: "yzILP",
            admin: admin,
            treasury: treasury,
            feeReceiver: feeReceiver,
            supplyCap: type(uint256).max,
            fillWindow: 1 days,
            minRedeemOrder: 0
        });
    }

    function _deploy(bytes32 salt) internal returns (YuzuILPV3) {
        vm.prank(deployer);
        return YuzuILPV3(factory.deploy(salt, impl, proxyAdminOwner, _params()));
    }

    function _proxyAdminOf(address proxy) internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(proxy, ERC1967_ADMIN_SLOT)))));
    }

    // --- constructor ---

    function test_Constructor_Revert_ZeroRoot() public {
        vm.expectRevert(YuzuILPV3Factory.InvalidZeroAddress.selector);
        new YuzuILPV3Factory(address(0));
    }

    function test_Constructor_RootHasOnlyDefaultAdmin() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), root));
        assertFalse(factory.hasRole(DEPLOYER_ROLE, root));
    }

    // --- access control ---

    function test_Deploy_Revert_NotDeployer() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, DEPLOYER_ROLE)
        );
        vm.prank(other);
        factory.deploy(SALT, impl, proxyAdminOwner, _params());
    }

    function test_Deploy_Revert_RevokedDeployer() public {
        vm.prank(root);
        factory.revokeRole(DEPLOYER_ROLE, deployer);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEPLOYER_ROLE)
        );
        vm.prank(deployer);
        factory.deploy(SALT, impl, proxyAdminOwner, _params());
    }

    // --- input validation ---

    function test_Deploy_Revert_ZeroImplementation() public {
        vm.expectRevert(YuzuILPV3Factory.InvalidZeroAddress.selector);
        vm.prank(deployer);
        factory.deploy(SALT, address(0), proxyAdminOwner, _params());
    }

    function test_Deploy_Revert_ZeroProxyAdminOwner() public {
        vm.expectRevert(YuzuILPV3Factory.InvalidZeroAddress.selector);
        vm.prank(deployer);
        factory.deploy(SALT, impl, address(0), _params());
    }

    // --- determinism ---

    function test_Deploy_MatchesPredictionAndEmits() public {
        address predicted = factory.predictAddress(SALT);

        vm.expectEmit(true, true, true, true);
        emit YuzuILPV3Factory.DeployedYuzuILPV3(predicted, SALT, impl, proxyAdminOwner);
        YuzuILPV3 vault = _deploy(SALT);

        assertEq(address(vault), predicted);
    }

    function test_PredictAddress_IndependentOfImplAndParams() public {
        bytes32 salt = keccak256("other.salt");
        address predicted = factory.predictAddress(salt);

        // Prediction is independent of implementation and init arguments.
        impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        YuzuILPV3Factory.InitParams memory params = _params();
        params.asset = address(_newAsset());
        params.name = "Other Name";
        params.supplyCap = 123e18;

        vm.prank(deployer);
        address vault = factory.deploy(salt, impl, proxyAdminOwner, params);

        assertEq(vault, predicted);
    }

    function test_Deploy_Revert_SaltReuse() public {
        _deploy(SALT);

        vm.expectRevert(CREATE3.DeploymentFailed.selector);
        vm.prank(deployer);
        factory.deploy(SALT, impl, proxyAdminOwner, _params());
    }

    // --- initialization state ---

    function test_Deploy_InitializesVaultState() public {
        YuzuILPV3 vault = _deploy(SALT);

        assertEq(vault.name(), "Yuzu ILP");
        assertEq(vault.symbol(), "yzILP");
        assertEq(vault.asset(), address(asset));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.feeReceiver(), feeReceiver);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(ADMIN_ROLE, admin));
        assertTrue(vault.isMintRestricted());
        assertTrue(vault.isRedeemRestricted());
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(vault.hasRole(ADMIN_ROLE, address(factory)));
    }

    function test_Deploy_ReachesVersionThree() public {
        YuzuILPV3 vault = _deploy(SALT);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.reinitialize();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        YuzuILP(address(vault)).initialize(address(asset), "x", "x", other, other, other, 0, 0, 0);
    }

    function test_Deploy_WiresV3RoleAdmins() public {
        YuzuILPV3 vault = _deploy(SALT);

        vm.startPrank(admin);
        vault.grantRole(FEE_MANAGER_ROLE, feeManager);
        vault.grantRole(THROTTLE_EXEMPT_ROLE, exempt);
        vm.stopPrank();

        assertTrue(vault.hasRole(FEE_MANAGER_ROLE, feeManager));
        assertTrue(vault.hasRole(THROTTLE_EXEMPT_ROLE, exempt));
    }

    // --- proxy admin ---

    function test_Deploy_ProxyAdminOwnedByGivenOwner() public {
        YuzuILPV3 vault = _deploy(SALT);
        assertEq(_proxyAdminOf(address(vault)).owner(), proxyAdminOwner);
    }

    function test_ProxyAdmin_CanUpgrade() public {
        YuzuILPV3 vault = _deploy(SALT);
        address newImpl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));

        vm.prank(proxyAdminOwner);
        _proxyAdminOf(address(vault)).upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), newImpl, "");

        assertEq(address(uint160(uint256(vm.load(address(vault), ERC1967_IMPL_SLOT)))), newImpl);
        assertEq(vault.name(), "Yuzu ILP");
    }

    // --- behavior ---

    function test_Deploy_VaultAcceptsDeposits() public {
        YuzuILPV3 vault = _deploy(SALT);

        vm.prank(admin);
        vault.setIsMintRestricted(false);

        asset.mint(user, 100e6);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, user);
        vm.stopPrank();

        assertEq(shares, 100e18);
        assertEq(vault.balanceOf(user), 100e18);
    }
}
