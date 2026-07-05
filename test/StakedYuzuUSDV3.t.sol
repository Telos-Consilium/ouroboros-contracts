// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {StakedYuzuUSDV3Migration} from "../src/StakedYuzuUSDV3Migration.sol";
import {StakedYuzuUSDV3RecoveryMigration} from "../src/StakedYuzuUSDV3RecoveryMigration.sol";
import {
    IntegrationConfig,
    IStakedYuzuUSDDefinitions,
    IStakedYuzuUSDV3Definitions
} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IYuzuThrottleDefinitions, Throttle} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {StakedYuzuUSDV3TestBase} from "./helpers/StakedYuzuUSDV3TestBase.sol";

contract StakedYuzuUSDV3Test is
    StakedYuzuUSDV3TestBase,
    IStakedYuzuUSDDefinitions,
    IStakedYuzuUSDV3Definitions,
    IYuzuThrottleDefinitions,
    IYuzuMinAmountsDefinitions
{
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public virtual {
        _setUpStakedYuzuUSDV3();
    }

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        return styz3.deposit(assets, user);
    }

    function _enableInstantRedeem() internal {
        vm.startPrank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.setIsInstantRedeemEnabled(true);
        vm.stopPrank();
    }

    // Recovery
    function test_Recovery() public view {
        assertEq(styz3.balanceOf(LOST_ADDRESS), 0);
        assertEq(styz3.balanceOf(RECOVERY_RECEIVER), RECOVERY_AMOUNT);
    }

    function test_MigrationWithoutRecovery_DoesNotRequireLostBalance() public {
        address freshOwner = makeAddr("freshOwner");
        address freshAdmin = makeAddr("freshAdmin");

        TransparentUpgradeableProxy proxy = _deployV1Proxy(freshOwner);
        ProxyAdmin freshProxyAdmin = _proxyAdmin(address(proxy));
        StakedYuzuUSDV3Migration freshStyz = StakedYuzuUSDV3Migration(address(proxy));

        vm.prank(freshOwner);
        freshStyz.pause();

        bytes memory migrationData = abi.encodeWithSelector(StakedYuzuUSDV3Migration.migrateToV3.selector, freshAdmin);
        _upgradeToMigration(freshProxyAdmin, proxy, freshOwner, migrationData);

        assertEq(freshStyz.balanceOf(LOST_ADDRESS), 0);
        assertEq(freshStyz.balanceOf(RECOVERY_RECEIVER), 0);
        assertEq(freshStyz.owner(), freshAdmin);
        assertTrue(freshStyz.hasRole(ADMIN_ROLE, freshAdmin));
    }

    function test_MigrationWithoutRecovery_BumpsPermitDomainToV2() public {
        address freshOwner = makeAddr("freshOwner");
        address freshAdmin = makeAddr("freshAdmin");

        TransparentUpgradeableProxy proxy = _deployV1Proxy(freshOwner);
        ProxyAdmin freshProxyAdmin = _proxyAdmin(address(proxy));
        StakedYuzuUSDV3Migration freshStyz = StakedYuzuUSDV3Migration(address(proxy));

        bytes32 domainSeparatorBefore = freshStyz.DOMAIN_SEPARATOR();

        vm.prank(freshOwner);
        freshStyz.pause();

        bytes memory migrationData = abi.encodeWithSelector(StakedYuzuUSDV3Migration.migrateToV3.selector, freshAdmin);
        _upgradeToMigration(freshProxyAdmin, proxy, freshOwner, migrationData);

        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(freshStyz.name())),
                keccak256(bytes("2")),
                block.chainid,
                address(proxy)
            )
        );

        assertTrue(freshStyz.DOMAIN_SEPARATOR() != domainSeparatorBefore);
        assertEq(freshStyz.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }

    // Reinitialize gate
    function test_Reinitialize_Revert_NotProxyAdmin() public {
        address freshOwner = makeAddr("freshOwner");
        address attacker = makeAddr("attacker");
        address freshAdmin = makeAddr("freshAdmin");

        (TransparentUpgradeableProxy proxy, ProxyAdmin freshProxyAdmin, StakedYuzuUSDV3Migration freshStyz) =
            _deploySeededV1Proxy(freshOwner);
        _upgradeToMigration(freshProxyAdmin, proxy, freshOwner, bytes(""));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, attacker));
        freshStyz.migrateToV3(attacker);

        vm.prank(freshAdmin);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, freshAdmin));
        freshStyz.migrateToV3(freshAdmin);
    }

    function test_MigrationInheritedOwnerMethods_Revert_NotAdmin() public {
        address freshOwner = makeAddr("freshOwner");
        address attacker = makeAddr("attacker");
        address freshAdmin = makeAddr("freshAdmin");

        (TransparentUpgradeableProxy proxy, ProxyAdmin freshProxyAdmin, StakedYuzuUSDV3Migration freshStyz) =
            _deploySeededV1Proxy(freshOwner);
        bytes memory migrationData =
            abi.encodeWithSelector(StakedYuzuUSDV3RecoveryMigration.migrateToV3.selector, freshAdmin);
        _upgradeToRecoveryMigration(freshProxyAdmin, proxy, freshOwner, migrationData);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        freshStyz.unpause();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        freshStyz.setIntegration(attacker, true, true);
        vm.stopPrank();

        vm.prank(freshAdmin);
        freshStyz.unpause();
        assertFalse(freshStyz.paused());
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

    function test_InitiateRedeem_Revert_UnderMinWithdraw() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.prank(admin);
        styz3.setMinWithdraw(10e18);

        _deposit(user1, 100e18);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 5e18, 10e18));
        styz3.initiateRedeem(5e18, user1, user1);

        vm.prank(user1);
        styz3.initiateRedeem(10e18, user1, user1); // at the floor, succeeds
    }

    // Public instant redeem
    function test_CanRedeem() public view {
        assertFalse(styz3.canRedeem(user1));
        assertFalse(styz3.canRedeem(user2));
    }

    function test_SetRedeemDelay_Revert_Zero() public {
        vm.startPrank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.expectRevert(abi.encodeWithSelector(RedeemDelayTooLow.selector, 0, 1));
        styz3.setRedeemDelay(0);
        vm.stopPrank();
    }

    function test_InstantWithdraw_PublicUser_PaysInstantFee() public {
        vm.startPrank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setRedeemDelay(7 days);
        styz3.setIsInstantRedeemEnabled(true);
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

    function test_PreviewRedeem_UsesInstantFee() public {
        vm.startPrank(admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setRedeemFee(50_000); // 5% delayed fee
        styz3.setInstantRedeemFee(200_000); // 20% instant fee
        vm.stopPrank();

        uint256 shares = _deposit(user1, 100e18);

        uint256 previewed = styz3.previewRedeem(shares);
        uint256 expected = uint256(100e18) - uint256(100e18) * 200_000 / (1_000_000 + 200_000);
        assertApproxEqAbs(previewed, expected, 1);
    }

    function test_Redeem_SkipDelayIntegration_PaysInstantFee() public {
        vm.startPrank(admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setRedeemFee(50_000); // 5% delayed fee
        styz3.setInstantRedeemFee(200_000); // 20% instant fee
        styz3.setIntegration(user1, true, false); // skipDelay, not waived
        vm.stopPrank();

        uint256 shares = _deposit(user1, 100e18);

        uint256 user1AssetsBefore = yzusd.balanceOf(user1);
        uint256 feeReceiverBefore = yzusd.balanceOf(feeReceiver);

        vm.prank(user1);
        uint256 assetsOut = styz3.redeem(shares, user1, user1);

        uint256 expectedAssets = uint256(100e18) - uint256(100e18) * 200_000 / (1_000_000 + 200_000);
        assertApproxEqAbs(assetsOut, expectedAssets, 1);
        assertApproxEqAbs(yzusd.balanceOf(user1) - user1AssetsBefore, expectedAssets, 1);
        assertApproxEqAbs(yzusd.balanceOf(feeReceiver) - feeReceiverBefore, 100e18 - expectedAssets, 1);
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

    // Instant redeem toggle
    function test_IsInstantRedeemEnabled_DefaultFalse() public view {
        assertFalse(styz3.isInstantRedeemEnabled());
    }

    function test_SetIsInstantRedeemEnabled_Revert_NotRedeemManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, REDEEM_MANAGER_ROLE)
        );
        styz3.setIsInstantRedeemEnabled(false);
    }

    function test_SetIsInstantRedeemEnabled_EmitsEvent() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit(false, false, false, true);
        emit UpdatedIsInstantRedeemEnabled(false, true);
        vm.prank(admin);
        styz3.setIsInstantRedeemEnabled(true);
        assertTrue(styz3.isInstantRedeemEnabled());
    }

    function test_InstantRedeemDisabled_Revert_PublicUser() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        assertFalse(styz3.canRedeem(user1));
        assertEq(styz3.maxWithdraw(user1), 0);
        assertEq(styz3.maxRedeem(user1), 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, shares, 0));
        styz3.redeem(shares, user1, user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 50e18, 0));
        styz3.withdraw(50e18, user1, user1);
    }

    function test_InstantRedeemDisabled_SkipDelayIntegration_StillRedeems() public {
        vm.startPrank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.setIntegration(user2, true, false);
        vm.stopPrank();

        // Integration owner retains view-level access
        assertTrue(styz3.canRedeem(user2));

        // Integration caller redeems on behalf of a public user
        uint256 shares = _deposit(user1, 100e18);
        vm.prank(user1);
        styz3.approve(user2, shares);

        vm.prank(user2);
        uint256 assetsOut = styz3.redeem(shares, user1, user1);
        assertGt(assetsOut, 0);
        assertEq(styz3.balanceOf(user1), 0);
    }

    function test_InstantRedeemDisabled_InitiateRedeem_Unaffected() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.prank(user1);
        (uint256 orderId, uint256 lockedAssets) = styz3.initiateRedeem(shares, user1, user1);
        assertGt(lockedAssets, 0);
        assertEq(orderId, 0);
    }

    function test_InstantRedeemReEnabled_PublicUser_Redeems() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.prank(admin);
        styz3.setIsInstantRedeemEnabled(true);

        vm.prank(user1);
        uint256 assetsOut = styz3.redeem(shares, user1, user1);
        assertGt(assetsOut, 0);
    }

    // Throttle
    function test_Throttle_UnlimitedByDefault() public {
        _enableInstantRedeem();

        Throttle memory mintThrottle = styz3.getMintThrottle();
        assertEq(mintThrottle.blockLimit, type(uint256).max);
        assertEq(mintThrottle.dailyLimit, type(uint256).max);
        Throttle memory redeemThrottle = styz3.getRedeemThrottle();
        assertEq(redeemThrottle.blockLimit, type(uint256).max);
        assertEq(redeemThrottle.dailyLimit, type(uint256).max);

        assertEq(styz3.maxDeposit(user1), type(uint256).max);

        uint256 shares = _deposit(user1, 1_000_000e18);
        vm.prank(user1);
        styz3.redeem(shares, user1, user1);
    }

    function test_Throttle_ZeroLimit_Halts() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.startPrank(admin);
        styz3.setMintThrottle(0, 0);
        styz3.setRedeemThrottle(0, 0);
        vm.stopPrank();

        assertEq(styz3.maxDeposit(user1), 0);
        assertEq(styz3.maxWithdraw(user1), 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user1, 1e18, 0));
        styz3.deposit(1e18, user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, shares, 0));
        styz3.redeem(shares, user1, user1);

        assertEq(styz3.maxRedeemOrder(user1), 0);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user1, shares, 0));
        styz3.initiateRedeem(shares, user1, user1);
    }

    function test_SetMintThrottle_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        styz3.setMintThrottle(100e18, 1000e18);
    }

    function test_SetRedeemThrottle_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        styz3.setRedeemThrottle(100e18, 1000e18);
    }

    function test_SetFeeReceiver_StaysAdmin() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        styz3.setFeeReceiver(newReceiver);
        assertEq(styz3.feeReceiver(), newReceiver);
    }

    function test_SetFeeReceiver_Revert_FeeManagerRejected() public {
        address feeManager = makeAddr("feeManager");
        vm.prank(admin);
        styz3.grantRole(FEE_MANAGER_ROLE, feeManager);

        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, ADMIN_ROLE)
        );
        styz3.setFeeReceiver(makeAddr("newReceiver"));
    }

    function test_SetMintThrottle_EmitsEvent() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.expectEmit(false, false, false, true);
        emit UpdatedMintThrottle(type(uint256).max, 100e18, type(uint256).max, 1000e18);
        vm.prank(admin);
        styz3.setMintThrottle(100e18, 1000e18);

        Throttle memory throttle = styz3.getMintThrottle();
        assertEq(throttle.blockLimit, 100e18);
        assertEq(throttle.dailyLimit, 1000e18);
    }

    function test_MintThrottle_BlockLimit() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(100e18, type(uint256).max);

        _deposit(user1, 60e18);
        assertEq(styz3.maxDeposit(user1), 40e18);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user1, 50e18, 40e18)
        );
        styz3.deposit(50e18, user1);

        vm.roll(block.number + 1);
        _deposit(user1, 50e18);
    }

    function test_MintThrottle_DailyLimit() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(type(uint256).max, 100e18);

        _deposit(user1, 60e18);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 hours);
        assertEq(styz3.maxDeposit(user1), 40e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user1, 50e18, 40e18)
        );
        styz3.deposit(50e18, user1);

        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        vm.roll(block.number + 1);
        _deposit(user1, 100e18);
    }

    function test_MintThrottle_DailyBoundary_ResetsAtMidnight() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(type(uint256).max, 100e18);

        vm.warp((block.timestamp / 1 days + 1) * 1 days - 60);
        _deposit(user1, 100e18);

        vm.warp(block.timestamp + 120);
        vm.roll(block.number + 1);
        _deposit(user1, 100e18);
    }

    function test_MintThrottle_Mint_Consumes() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(100e18, type(uint256).max);

        uint256 shares = styz3.previewDeposit(60e18);
        vm.prank(user1);
        styz3.mint(shares, user1);

        uint256 overShares = styz3.previewDeposit(50e18);
        uint256 maxShares = styz3.maxMint(user1);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, user1, overShares, maxShares)
        );
        styz3.mint(overShares, user1);
    }

    function test_ThrottleExemptRole_AdminIsAdminRole() public view {
        assertEq(styz3.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE);
    }

    function test_ThrottleExemptRole_Grant_Revert_NotRoleAdmin() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE)
        );
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
    }

    function test_RedeemThrottle_SkipDelayIntegration_NotExempt_Throttled() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setIntegration(user2, true, false);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 500e18);

        // Skip-delay status alone no longer grants throttle exemption
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ExceededRedeemBlockLimit.selector, 100e18, 50e18));
        styz3.withdraw(100e18, user2, user2);
    }

    function test_MintThrottle_ThrottleExempt_Bypasses() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setMintThrottle(100e18, type(uint256).max);
        vm.stopPrank();

        assertEq(styz3.maxDeposit(user2), type(uint256).max);

        vm.prank(user2);
        styz3.deposit(150e18, user2);
        assertEq(styz3.getMintThrottle().usedInBlock, 0);

        // Public budget is untouched by the exempt deposit
        _deposit(user1, 100e18);
    }

    function test_MintThrottle_ExemptReceiver_BypassesForAnyCaller() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setMintThrottle(100e18, type(uint256).max);
        vm.stopPrank();

        // The throttle keys on the receiver, matching maxDeposit, so any caller can fund an
        // exempt receiver
        assertEq(styz3.maxDeposit(user2), type(uint256).max);
        vm.prank(user1);
        styz3.deposit(150e18, user2);
        assertEq(styz3.getMintThrottle().usedInBlock, 0);
    }

    function test_MintThrottle_ExemptCaller_NonExemptReceiver_Capped() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user1);
        styz3.setMintThrottle(100e18, type(uint256).max);
        vm.stopPrank();

        // Caller exemption confers nothing; the receiver's throttled maxDeposit governs
        assertEq(styz3.maxDeposit(user2), 100e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, user2, 150e18, 100e18)
        );
        styz3.deposit(150e18, user2);
    }

    // Views and consumption share the same principal, so a max-sized call succeeds for any caller
    function testFuzz_MaxDeposit_NeverOverstates_ForAnyCaller(uint256 cap, uint256 assets) public {
        cap = bound(cap, 1e18, 1000e18);
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setMintThrottle(cap, type(uint256).max);
        vm.stopPrank();

        uint256 maxAssets = styz3.maxDeposit(user2);
        assets = bound(assets, 1, maxAssets);
        vm.prank(user1);
        styz3.deposit(assets, user2);
    }

    function testFuzz_MaxWithdraw_NeverOverstates_ForAnyCaller(uint256 cap, uint256 assets) public {
        _enableInstantRedeem();
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        // Diverging fee rates: the owner is fee-waived while the caller pays the instant fee, so the
        // throttle's fee basis must follow the owner for the view to stay exact
        styz3.setInstantRedeemFee(100_000);
        styz3.setIntegration(user2, false, true);
        vm.stopPrank();

        _deposit(user2, 1000e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        cap = bound(cap, 1e18, 500e18);
        vm.prank(admin);
        styz3.setRedeemThrottle(cap, type(uint256).max);

        uint256 maxAssets = styz3.maxWithdraw(user2);
        assets = bound(assets, 1, maxAssets);
        vm.prank(user1);
        styz3.withdraw(assets, user1, user2);
    }

    function test_RedeemThrottle_BlockLimit_GrossIncludesFee() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.setIsInstantRedeemEnabled(true);
        styz3.setInstantRedeemFee(200_000); // 20% instant fee
        vm.stopPrank();

        _deposit(user1, 1000e18);

        vm.prank(admin);
        styz3.setRedeemThrottle(120e18, type(uint256).max);

        // Gross capacity 120e18 supports a net withdrawal of 100e18 plus 20e18 fee
        assertEq(styz3.maxWithdraw(user1), 100e18);

        vm.prank(user1);
        styz3.withdraw(100e18, user1, user1);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 120e18);
        assertEq(styz3.maxWithdraw(user1), 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 1e18, 0));
        styz3.withdraw(1e18, user1, user1);

        vm.roll(block.number + 1);
        vm.prank(user1);
        styz3.withdraw(50e18, user1, user1);
    }

    function test_RedeemThrottle_Redeem_ConsumesAtMaxRedeem() public {
        _enableInstantRedeem();

        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        _deposit(user1, 1000e18);

        vm.prank(admin);
        styz3.setRedeemThrottle(120e18, type(uint256).max);

        uint256 maxShares = styz3.maxRedeem(user1);
        assertEq(maxShares, styz3.convertToShares(120e18));

        vm.prank(user1);
        styz3.redeem(maxShares, user1, user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, user1, 1e18, 0));
        styz3.redeem(1e18, user1, user1);
    }

    function test_RedeemThrottle_DailyLimit() public {
        _enableInstantRedeem();

        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        _deposit(user1, 1000e18);

        vm.prank(admin);
        styz3.setRedeemThrottle(type(uint256).max, 100e18);

        vm.prank(user1);
        styz3.withdraw(60e18, user1, user1);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 hours);
        assertEq(styz3.maxWithdraw(user1), 40e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user1, 50e18, 40e18)
        );
        styz3.withdraw(50e18, user1, user1);

        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        vm.roll(block.number + 1);
        vm.prank(user1);
        styz3.withdraw(50e18, user1, user1);
    }

    function test_RedeemThrottle_ThrottleExempt_Bypasses() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setIsInstantRedeemEnabled(true);
        styz3.setRedeemThrottle(10e18, type(uint256).max);
        vm.stopPrank();

        uint256 shares = _deposit(user2, 500e18);

        vm.prank(user2);
        styz3.redeem(shares, user2, user2);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 0);
    }

    function test_RedeemThrottle_ExemptOwner_BypassesForAnyCaller() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setIsInstantRedeemEnabled(true);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 500e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        // The throttle keys on the owner, matching maxWithdraw, so the exempt owner's shares
        // bypass it for any caller
        vm.prank(user1);
        styz3.withdraw(100e18, user1, user2);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 0);
    }

    function test_RedeemThrottle_ExemptCaller_NonExemptOwner_Capped() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user1);
        styz3.setIsInstantRedeemEnabled(true);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 500e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        // Caller exemption confers nothing; the owner's throttled maxWithdraw governs
        assertEq(styz3.maxWithdraw(user2), 50e18);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, user2, 100e18, 50e18)
        );
        styz3.withdraw(100e18, user1, user2);
    }

    function test_RedeemThrottle_InitiateRedeem_Consumes() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        _deposit(user1, 100e18);

        vm.prank(admin);
        styz3.setRedeemThrottle(50e18, type(uint256).max);

        assertEq(styz3.maxRedeemOrder(user1), 50e18);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user1, 100e18, 50e18));
        styz3.initiateRedeem(100e18, user1, user1);

        vm.prank(user1);
        (, uint256 lockedAssets) = styz3.initiateRedeem(50e18, user1, user1);
        assertGt(lockedAssets, 0);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 50e18);
    }

    function test_RedeemThrottle_InitiateRedeem_ExemptCallerForNonExemptOwner_Throttled() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user1);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 100e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        assertEq(styz3.maxRedeemOrder(user2), 50e18);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user2, 100e18, 50e18));
        styz3.initiateRedeem(100e18, user1, user2);
    }

    function test_RedeemThrottle_InitiateRedeem_NonExemptCallerForExemptOwner_Bypasses() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 100e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        assertEq(styz3.maxRedeemOrder(user2), 100e18);
        vm.prank(user1);
        (, uint256 lockedAssets) = styz3.initiateRedeem(100e18, user1, user2);

        assertGt(lockedAssets, 0);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 0);
    }

    function test_RedeemThrottle_InitiateRedeem_IntegrationFeeWaiverIgnored() public {
        vm.startPrank(admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setRedeemFee(100_000);
        styz3.setMinWithdraw(100e18);
        styz3.setIntegration(user1, false, true);
        vm.stopPrank();

        _deposit(user2, 100e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        assertEq(styz3.maxRedeemOrder(user2), 0);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeemOrder.selector, user2, 100e18, 0));
        styz3.initiateRedeem(100e18, user1, user2);
    }

    // Max view exactness (ERC-4626 compliance)
    function test_MaxMint_UnlimitedByDefault() public view {
        assertEq(styz3.maxMint(user1), type(uint256).max);
    }

    function test_MaxMint_Throttled_ConvertsRemaining() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(100e18, type(uint256).max);

        assertEq(styz3.maxMint(user1), styz3.previewDeposit(100e18));
    }

    function test_MaxMint_UnlimitedAboveParPrice() public {
        // Keep the mint throttle at its unlimited default.
        vm.startPrank(admin);
        styz3.grantRole(POOL_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user1);
        vm.stopPrank();

        _deposit(user1, 1000e18);

        // Raise the share price above 1 via a completed distribution
        yzusd.mint(admin, 500e18);
        vm.prank(admin);
        yzusd.approve(address(styz3), 500e18);
        vm.prank(admin);
        styz3.distribute(500e18, 1);
        vm.warp(block.timestamp + 2);
        assertGt(styz3.convertToAssets(1e18), 1e18);

        // Unlimited throttle converts uint256.max assets to shares with no overflow
        assertEq(styz3.maxMint(user2), styz3.previewDeposit(type(uint256).max));
    }

    function test_MaxDeposit_MaxMint_BelowMinDeposit_ReturnZero() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setMinDeposit(100e18);
        styz3.setMintThrottle(50e18, type(uint256).max); // remaining below minDeposit
        vm.stopPrank();

        assertEq(styz3.maxDeposit(user1), 0);
        assertEq(styz3.maxMint(user1), 0);

        // Entry points revert with UnderMin, not ExceededMax.
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 50e18, 100e18));
        styz3.deposit(50e18, user1);
    }

    function test_MaxWithdraw_MaxRedeem_BelowMinWithdraw_ReturnZero() public {
        _deposit(user1, 50e18);

        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMinWithdraw(100e18); // balance worth less than minWithdraw

        assertEq(styz3.maxWithdraw(user1), 0);
        assertEq(styz3.maxRedeem(user1), 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 50e18, 100e18));
        styz3.withdraw(50e18, user1, user1);
    }

    function test_MaxWithdraw_AtMinWithdraw_NotClamped() public {
        _deposit(user1, 100e18);
        uint256 achievable = styz3.maxWithdraw(user1);

        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMinWithdraw(achievable);

        // Achievable max equals the floor exactly, so it is reported (not clamped) and is withdrawable
        assertEq(styz3.maxWithdraw(user1), achievable);
        vm.prank(user1);
        styz3.withdraw(achievable, user1, user1);
    }

    // Distribution guards

    function _setupDistribute() internal {
        vm.startPrank(admin);
        styz3.grantRole(POOL_MANAGER_ROLE, owner);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setMaxDistributionPpm(100_000);
        styz3.setMinDistributionPeriod(6 hours);
        vm.stopPrank();
        _deposit(user1, 1000e18);
    }

    function test_Reinitialize_DistributionGuardsDefaultOff() public view {
        assertEq(styz3.maxDistributionPpm(), type(uint256).max);
        assertEq(styz3.minDistributionPeriod(), 0);
    }

    function test_Distribute_WithinCap() public {
        _setupDistribute();
        uint256 maxAssets = Math.mulDiv(styz3.totalAssets(), styz3.maxDistributionPpm(), 1e6);
        vm.prank(owner);
        styz3.distribute(maxAssets / 2, 1 days);
        assertEq(styz3.lastDistributedAmount(), maxAssets / 2);
    }

    function test_Distribute_AtCap() public {
        _setupDistribute();
        uint256 maxAssets = Math.mulDiv(styz3.totalAssets(), styz3.maxDistributionPpm(), 1e6);
        vm.prank(owner);
        styz3.distribute(maxAssets, 1 days);
        assertEq(styz3.lastDistributedAmount(), maxAssets);
    }

    function test_Distribute_Revert_OverCap() public {
        _setupDistribute();
        uint256 maxAssets = Math.mulDiv(styz3.totalAssets(), styz3.maxDistributionPpm(), 1e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DistributionAmountTooHigh.selector, maxAssets + 1, maxAssets));
        styz3.distribute(maxAssets + 1, 1 days);
    }

    function test_Distribute_CapDisabled() public {
        _setupDistribute();
        vm.prank(admin);
        styz3.setMaxDistributionPpm(type(uint256).max);

        vm.prank(owner);
        styz3.distribute(500e18, 1 days);
        assertEq(styz3.lastDistributedAmount(), 500e18);
    }

    function test_Distribute_AtMinPeriod() public {
        _setupDistribute();
        vm.prank(owner);
        styz3.distribute(50e18, 6 hours);
        assertEq(styz3.lastDistributionPeriod(), 6 hours);
    }

    function test_Distribute_Revert_BelowMinPeriod() public {
        _setupDistribute();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooLow.selector, 6 hours - 1, 6 hours));
        styz3.distribute(50e18, 6 hours - 1);
    }

    function test_SetMaxDistributionPpm_Updates() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.expectEmit(false, false, false, true, address(styz3));
        emit UpdatedMaxDistributionPpm(type(uint256).max, 50_000);
        vm.prank(admin);
        styz3.setMaxDistributionPpm(50_000);
        assertEq(styz3.maxDistributionPpm(), 50_000);
    }

    function test_SetMinDistributionPeriod_Revert_TooHigh() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooHigh.selector, 7 days + 1, 7 days));
        styz3.setMinDistributionPeriod(7 days + 1);
    }

    function test_SetMaxDistributionPpm_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        styz3.setMaxDistributionPpm(50_000);
    }
}
