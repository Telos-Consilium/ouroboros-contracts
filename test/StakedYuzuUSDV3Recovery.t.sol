// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3Recovery} from "../src/StakedYuzuUSDV3Recovery.sol";
import {
    IntegrationConfig,
    IStakedYuzuUSDDefinitions,
    IStakedYuzuUSDV3Definitions
} from "../src/interfaces/IStakedYuzuUSDDefinitions.sol";
import {IYuzuThrottleDefinitions, Throttle} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";

contract StakedYuzuUSDV3RecoveryTest is
    Test,
    IStakedYuzuUSDDefinitions,
    IStakedYuzuUSDV3Definitions,
    IYuzuThrottleDefinitions
{
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
    bytes32 constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

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

    // Reinitialize gate
    function test_Reinitialize_Revert_NotProxyAdmin() public {
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

        _approveAssets(user1, address(freshStyz), type(uint256).max);
        vm.prank(user1);
        freshStyz.deposit(RECOVERY_AMOUNT, LOST_ADDRESS);

        vm.prank(freshOwner);
        freshStyz.pause();

        address v3Impl = _deploy();
        vm.prank(freshOwner);
        freshProxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(payable(address(proxy))), v3Impl, bytes(""));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, attacker));
        freshStyz.reinitialize(attacker);

        vm.prank(freshAdmin);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedReinitializer.selector, freshAdmin));
        freshStyz.reinitialize(freshAdmin);
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
    function test_IsInstantRedeemEnabled_DefaultTrue() public view {
        assertTrue(styz3.isInstantRedeemEnabled());
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
        emit UpdatedIsInstantRedeemEnabled(true, false);
        vm.prank(admin);
        styz3.setIsInstantRedeemEnabled(false);
        assertFalse(styz3.isInstantRedeemEnabled());
    }

    function test_InstantRedeemDisabled_PublicUser_Reverts() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.prank(admin);
        styz3.setIsInstantRedeemEnabled(false);

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
        styz3.setIsInstantRedeemEnabled(false);
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

        vm.prank(admin);
        styz3.setIsInstantRedeemEnabled(false);

        vm.prank(user1);
        (uint256 orderId, uint256 lockedAssets) = styz3.initiateRedeem(shares, user1, user1);
        assertGt(lockedAssets, 0);
        assertEq(orderId, 0);
    }

    function test_InstantRedeemReEnabled_PublicUser_Redeems() public {
        vm.prank(admin);
        styz3.grantRole(REDEEM_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.startPrank(admin);
        styz3.setIsInstantRedeemEnabled(false);
        styz3.setIsInstantRedeemEnabled(true);
        vm.stopPrank();

        vm.prank(user1);
        uint256 assetsOut = styz3.redeem(shares, user1, user1);
        assertGt(assetsOut, 0);
    }

    // Throttle
    function test_Throttle_UnlimitedByDefault() public {
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

        // The delayed path is not throttled
        vm.prank(user1);
        (, uint256 lockedAssets) = styz3.initiateRedeem(shares, user1, user1);
        assertGt(lockedAssets, 0);
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

    function test_RedeemThrottle_BlockLimit_GrossIncludesFee() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(FEE_MANAGER_ROLE, admin);
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
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setRedeemThrottle(10e18, type(uint256).max);
        vm.stopPrank();

        uint256 shares = _deposit(user2, 500e18);

        vm.prank(user2);
        styz3.redeem(shares, user2, user2);
        assertEq(styz3.getRedeemThrottle().usedInBlock, 0);
    }

    function test_RedeemThrottle_NonExemptCaller_ConsumesForExemptOwner() public {
        vm.startPrank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.grantRole(THROTTLE_EXEMPT_ROLE, user2);
        styz3.setRedeemThrottle(50e18, type(uint256).max);
        vm.stopPrank();

        _deposit(user2, 500e18);
        vm.prank(user2);
        styz3.approve(user1, type(uint256).max);

        // maxWithdraw(user2) is exempt, so the throttle reverts at consumption
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExceededRedeemBlockLimit.selector, 100e18, 50e18));
        styz3.withdraw(100e18, user1, user2);
    }

    function test_RedeemThrottle_InitiateRedeem_NotThrottled() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        uint256 shares = _deposit(user1, 100e18);

        vm.prank(admin);
        styz3.setRedeemThrottle(1, 1);

        vm.prank(user1);
        (, uint256 lockedAssets) = styz3.initiateRedeem(shares, user1, user1);
        assertGt(lockedAssets, 0);
    }

    // Max view exactness (ERC-4626 compliance)
    function test_MaxMint_UnlimitedByDefault_NoRevert() public view {
        assertEq(styz3.maxMint(user1), type(uint256).max);
    }

    function test_MaxMint_Throttled_ConvertsRemaining() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        styz3.setMintThrottle(100e18, type(uint256).max);

        assertEq(styz3.maxMint(user1), styz3.previewDeposit(100e18));
    }

    function test_MaxMint_UnlimitedAboveParPrice_NoRevert() public {
        // Exempt the depositor so the mint throttle stays pristine (remaining == uint256.max)
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

        // Entry points revert with the precise UnderMin error, not ExceededMax
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

    // --- distribute cap (upper-only, syzUSD NAV is monotonic up) + min-period floor ---

    // Grants POOL_MANAGER to owner (who funds the distribution) and LIMIT_MANAGER to admin, turns the
    // guards on (10% cap, 6h floor), and funds the vault so totalAssets is ~1000e18 and 10% floors to 100e18.
    function _setupDistribute() internal {
        vm.startPrank(admin);
        styz3.grantRole(POOL_MANAGER_ROLE, owner);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        styz3.setMaxDistributePpm(100_000);
        styz3.setMinDistributionPeriod(6 hours);
        vm.stopPrank();
        _deposit(user1, 1000e18);
    }

    function test_Reinitialize_DistributeGuardsShipOff() public view {
        assertEq(styz3.maxDistributePpm(), type(uint256).max);
        assertEq(styz3.minDistributionPeriod(), 0);
    }

    function test_Distribute_WithinCap() public {
        _setupDistribute();
        vm.prank(owner);
        styz3.distribute(50e18, 1 days);
        assertEq(styz3.lastDistributedAmount(), 50e18);
    }

    function test_Distribute_AtCap() public {
        _setupDistribute();
        vm.prank(owner);
        styz3.distribute(100e18, 1 days);
        assertEq(styz3.lastDistributedAmount(), 100e18);
    }

    function test_Distribute_Revert_OverCap() public {
        _setupDistribute();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DistributionAmountTooHigh.selector, 100e18 + 1, 100e18));
        styz3.distribute(100e18 + 1, 1 days);
    }

    function test_Distribute_CapDisabled() public {
        _setupDistribute();
        vm.prank(admin);
        styz3.setMaxDistributePpm(type(uint256).max);

        // 500e18 is 50% of TVL, far above the 10% cap, but the cap is disabled
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

    function test_SetMaxDistributePpm_Updates() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.expectEmit(false, false, false, true, address(styz3));
        emit UpdatedMaxDistributePpm(type(uint256).max, 50_000);
        vm.prank(admin);
        styz3.setMaxDistributePpm(50_000);
        assertEq(styz3.maxDistributePpm(), 50_000);
    }

    function test_SetMinDistributionPeriod_Revert_TooHigh() public {
        vm.prank(admin);
        styz3.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(DistributionPeriodTooHigh.selector, 7 days + 1, 7 days));
        styz3.setMinDistributionPeriod(7 days + 1);
    }

    function test_SetMaxDistributePpm_Revert_NotLimitManager() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIMIT_MANAGER_ROLE)
        );
        styz3.setMaxDistributePpm(50_000);
    }
}
