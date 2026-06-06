// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3Recovery} from "../src/StakedYuzuUSDV3Recovery.sol";
import {IntegrationConfig, IStakedYuzuUSDV3Definitions} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";

contract StakedYuzuUSDV3RecoveryTest is Test, IStakedYuzuUSDV3Definitions {
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    StakedYuzuUSDV3Recovery public styz3;
    ProxyAdmin public proxyAdmin;
    ERC20Mock public yzusd;

    address public owner;
    address public feeReceiver;
    address public user1;
    address public user2;
    address public admin;
    address public pauseManager;

    address constant LOST_ADDRESS = address(0x01);
    address constant RECOVERY_RECEIVER = address(0x02);
    uint256 constant RECOVERY_AMOUNT = 1;

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
    bytes32 constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    function setUp() public virtual {
        owner = makeAddr("owner");
        feeReceiver = makeAddr("feeReceiver");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        admin = makeAddr("admin");
        pauseManager = makeAddr("pauseManager");

        // Deploy mock asset and mint balances
        yzusd = new ERC20Mock();
        yzusd.mint(owner, 10_000_000e18);
        yzusd.mint(user1, 10_000_000e18);
        yzusd.mint(user2, 10_000_000e18);

        // Deploy V1 implementation behind a TransparentUpgradeableProxy (mirrors production)
        address v1Impl = address(new StakedYuzuUSD());
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            owner,
            feeReceiver,
            1 days
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(v1Impl, owner, initData);
        proxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), _ADMIN_SLOT)))));
        styz3 = StakedYuzuUSDV3Recovery(address(proxy));

        // Approvals for deposits
        _approveAssets(owner, address(styz3), type(uint256).max);
        _approveAssets(user1, address(styz3), type(uint256).max);
        _approveAssets(user2, address(styz3), type(uint256).max);

        // Pre-reinit: LOST_ADDRESS needs RECOVERY_AMOUNT shares so the recovery burn succeeds
        vm.prank(user1);
        styz3.deposit(RECOVERY_AMOUNT, LOST_ADDRESS);

        // Production V2-side pause before the upgrade
        vm.prank(owner);
        styz3.pause();

        // Upgrade to V3Recovery atomically via ProxyAdmin.upgradeAndCall; reinitialize
        // gate requires msg.sender == proxy admin, so the upgrade-and-init must be atomic.
        address v3Impl = _deploy();
        bytes memory reinitData = abi.encodeWithSelector(StakedYuzuUSDV3Recovery.reinitialize.selector, admin);
        vm.prank(owner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), v3Impl, reinitData);

        // Bootstrap PAUSE_MANAGER_ROLE so we can unpause for subsequent tests
        vm.prank(admin);
        styz3.grantRole(PAUSE_MANAGER_ROLE, pauseManager);

        vm.prank(pauseManager);
        styz3.unpause();
    }

    function _deploy() internal virtual returns (address) {
        return address(new StakedYuzuUSDV3Recovery());
    }

    // Helpers
    function _approveAssets(address _owner, address spender, uint256 amount) internal {
        vm.prank(_owner);
        yzusd.approve(spender, amount);
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return styz3.deposit(assets, user);
    }

    // Recovery
    function test_Recovery() public view {
        assertEq(styz3.balanceOf(LOST_ADDRESS), 0);
        assertEq(styz3.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT);
    }

    // AccessControl migration
    function test_Owner_ReturnsAdmin() public view {
        assertEq(styz3.owner(), admin);
    }

    function test_RolesGranted() public view {
        assertTrue(styz3.hasRole(styz3.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(styz3.hasRole(ADMIN_ROLE, admin));
    }

    function test_TransferOwnership_Revert() public {
        vm.expectRevert(OwnershipMigratedToAccessControl.selector);
        styz3.transferOwnership(user1);
    }

    function test_SetIntegration() public {
        vm.prank(admin);
        styz3.setIntegration(user1, true, true);

        IntegrationConfig memory cfg = styz3.getIntegration(user1);
        assertTrue(cfg.canSkipRedeemDelay);
        assertTrue(cfg.waiveRedeemFee);
    }

    function test_SetIntegration_Revert_NotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        styz3.setIntegration(user1, true, true);
    }

    // Min mint/redeem
    function test_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.prank(admin);
        styz3.setMinDeposit(10e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e18, 10e18));
        styz3.deposit(5e18, user1);
    }

    function test_Withdraw_Revert_UnderMinWithdraw() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.prank(admin);
        styz3.setMinWithdraw(10e18);

        _deposit(user1, 100e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 5e18, 10e18));
        styz3.withdraw(5e18, user1, user1);
    }

    // Public instant redeem
    function test_CanRedeem() public view {
        assertTrue(styz3.canRedeem(user1));
        assertTrue(styz3.canRedeem(user2));
    }

    function test_InstantWithdraw_PublicUser_PaysInstantFee() public {
        vm.startPrank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setRedeemDelay(7 days);
        styz3.setInstantRedeemFee(100_000); // 10% instant fee
        vm.stopPrank();

        uint256 assets = 100e18;
        _deposit(user1, assets);

        uint256 user1AssetsBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBefore = yzusd.balanceOf(feeReceiver);

        uint256 withdrawAmount = 90e18;
        uint256 expectedFee = withdrawAmount * 100_000 / 1_000_000;

        vm.prank(user1);
        styz3.withdraw(withdrawAmount, user1, user1);

        assertEq(yzusd.balanceOf(user1) - user1AssetsBefore, withdrawAmount);
        assertApproxEqAbs(yzusd.balanceOf(feeReceiver) - feeReceiverBefore, expectedFee, 1);
    }

    function test_FrontrunReinitialize_Revert_NotProxyAdmin() public {
        // Simulate the non-atomic upgrade window: deploy a fresh V1 proxy, upgrade to
        // V3Recovery WITHOUT the atomic init payload, then attempt to front-run
        // reinitialize from a non-proxy-admin caller.
        address freshOwner = makeAddr("freshOwner");
        address attacker = makeAddr("attacker");
        address freshAdmin = makeAddr("freshAdmin");

        address v1Impl = address(new StakedYuzuUSD());
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "st-yzUSD",
            freshOwner,
            feeReceiver,
            1 days
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(v1Impl, freshOwner, initData);
        ProxyAdmin freshProxyAdmin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), _ADMIN_SLOT)))));
        StakedYuzuUSDV3Recovery freshStyz = StakedYuzuUSDV3Recovery(address(proxy));

        // Seed LOST_ADDRESS so the recovery burn would succeed if reached
        _approveAssets(user1, address(freshStyz), type(uint256).max);
        vm.prank(user1);
        freshStyz.deposit(RECOVERY_AMOUNT, LOST_ADDRESS);

        vm.prank(freshOwner);
        freshStyz.pause();

        // Upgrade WITHOUT the atomic reinit payload (the non-atomic operator mistake)
        address v3Impl = _deploy();
        vm.prank(freshOwner);
        freshProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), v3Impl, bytes(""));

        // Attacker front-runs the legitimate reinit; gate rejects
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, attacker));
        freshStyz.reinitialize(attacker);

        // Even the intended admin EOA cannot bypass; only the ProxyAdmin contract can drive reinit
        vm.prank(freshAdmin);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, freshAdmin));
        freshStyz.reinitialize(freshAdmin);
    }

    function test_InitiateRedeem_UsesRedeemFee_NotInstantFee() public {
        vm.startPrank(admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setRedeemFee(50_000); // 5% delayed fee
        styz3.setInstantRedeemFee(200_000); // 20% instant fee (distinguishable from delayed)
        vm.stopPrank();

        uint256 shares = _deposit(user1, 100e18);

        vm.prank(user1);
        (, uint256 lockedAssets) = styz3.initiateRedeem(shares, user1, user1);

        // Delayed path should apply redeemFeePpm (5%), not instantRedeemFeePpm (20%)
        // Net assets locked ~= 100e18 * 1e6 / (1e6 + 50_000) = 100e18 * 1_000_000 / 1_050_000
        uint256 expectedNet = uint256(100e18) * 1_000_000 / 1_050_000;
        assertApproxEqRel(lockedAssets, expectedNet, 0.001e18); // 0.1% tolerance
    }
}
