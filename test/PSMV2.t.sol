// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PSM} from "../src/PSM.sol";
import {PSMV2} from "../src/PSMV2.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3} from "../src/StakedYuzuUSDV3.sol";
import {IYuzuThrottleDefinitions, Throttle} from "../src/interfaces/proto/IYuzuThrottleDefinitions.sol";
import {IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";

import {
    ADMIN_ROLE,
    BURNER_ROLE,
    DELAY_EXEMPT_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    LIQUIDITY_MANAGER_ROLE,
    MINTER_ROLE,
    ORDER_FILLER_ROLE,
    PAUSE_MANAGER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    REDEEMER_ROLE,
    RESTRICTION_MANAGER_ROLE,
    THROTTLE_EXEMPT_ROLE,
    USER_ROLE
} from "./helpers/TestRoles.sol";
import {PSMTest} from "./PSM.t.sol";

contract PSMV2Test is PSMTest {
    PSMV2 public psmV2;

    // PSMV2 requires vault1 to expose currentBlockRestrictedBalance(address) and
    // redeemThrottleRemaining(address). The parent fixture uses V2 syzUSD, so this suite deploys
    // V3 syzUSD and a separate PSMV2 while inherited PSM tests keep the parent vaults.
    StakedYuzuUSDV3 public styzV3;

    address public limitManager;
    address public throttleExempt;
    address public styzOwner;

    uint256 internal constant LIQUIDITY = 5_000_000e6;

    function setUp() public override {
        super.setUp();

        limitManager = makeAddr("limitManager");
        throttleExempt = makeAddr("throttleExempt");
        styzOwner = makeAddr("styzOwner");

        // Deploy V3 syzUSD so vault1 exposes both views required by PSMV2
        styzV3 = _deployStakedYuzuUSDV3();
        vm.label(address(styzV3), "Staked Yuzu USD V3 (proxy)");

        // Deploy PSMV2 with yzUSD as vault0 and V3 syzUSD as vault1
        PSMV2 implementation = new PSMV2();
        bytes memory initData = abi.encodeWithSelector(PSM.initialize.selector, asset, yzusd, styzV3, admin, 0);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        psmV2 = PSMV2(address(proxy));
        psmV2.reinitialize();

        vm.label(address(psmV2), "PSMV2 (proxy)");

        // The PSM's inner syzUSD redemption must remain immediate and fee-free.
        vm.startPrank(admin);
        styzV3.grantRole(DELAY_EXEMPT_ROLE, address(psmV2));
        styzV3.grantRole(REDEEM_FEE_EXEMPT_ROLE, address(psmV2));
        yzusd.grantRole(MINTER_ROLE, address(psmV2));
        yzusd.grantRole(REDEEMER_ROLE, address(psmV2));
        yzusd.grantRole(BURNER_ROLE, address(psmV2));
        psmV2.grantRole(ORDER_FILLER_ROLE, orderFiller);
        psmV2.grantRole(LIQUIDITY_MANAGER_ROLE, liquidityManager);
        psmV2.grantRole(RESTRICTION_MANAGER_ROLE, restrictionManager);
        psmV2.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        psmV2.grantRole(THROTTLE_EXEMPT_ROLE, throttleExempt);
        vm.stopPrank();

        vm.startPrank(restrictionManager);
        psmV2.grantRole(USER_ROLE, user1);
        psmV2.grantRole(USER_ROLE, user2);
        psmV2.grantRole(USER_ROLE, throttleExempt);
        vm.stopPrank();

        // Approvals: USDT0 in, syzUSD out (PSM pulls the owner's shares on redeem)
        _approveAssets(user1, address(psmV2), type(uint256).max);
        _approveAssets(user2, address(psmV2), type(uint256).max);
        _approveAssets(liquidityManager, address(psmV2), type(uint256).max);
        _approveStakedV3(user1, address(psmV2), type(uint256).max);
        _approveStakedV3(user2, address(psmV2), type(uint256).max);

        // Give the exempt account a balance and approvals too
        asset.mint(throttleExempt, 10_000_000e6);
        _approveAssets(throttleExempt, address(psmV2), type(uint256).max);
        _approveStakedV3(throttleExempt, address(psmV2), type(uint256).max);

        // Fund the instant-redeem liquidity pool
        vm.prank(liquidityManager);
        psmV2.depositLiquidity(LIQUIDITY);
    }

    // Deploys StakedYuzuUSD at V1 behind a transparent proxy, pauses, upgrades to V3 through the
    // proxy-admin-gated reinitializer, then unpauses.
    function _deployStakedYuzuUSDV3() internal returns (StakedYuzuUSDV3 deployed) {
        address v1Impl = address(new StakedYuzuUSD());
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "syzUSD",
            styzOwner,
            feeReceiver,
            1 days
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(v1Impl, styzOwner, initData);
        ProxyAdmin proxyAdmin = ProxyAdmin(
            address(
                uint160(
                    uint256(vm.load(address(proxy), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103))
                )
            )
        );

        vm.prank(styzOwner);
        StakedYuzuUSD(address(proxy)).pause();

        address v3Impl = address(new StakedYuzuUSDV3());
        vm.prank(styzOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(proxy))),
            v3Impl,
            abi.encodeWithSelector(StakedYuzuUSDV3.reinitialize.selector, admin)
        );

        deployed = StakedYuzuUSDV3(address(proxy));
        vm.startPrank(admin);
        deployed.grantRole(PAUSE_MANAGER_ROLE, admin);
        deployed.unpause();
        vm.stopPrank();
    }

    function _approveStakedV3(address _owner, address spender, uint256 amount) internal {
        vm.prank(_owner);
        styzV3.approve(spender, amount);
    }

    // --- helpers ---

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = psmV2.deposit(assets, user);
    }

    function _redeem(address user, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = psmV2.redeem(shares, user, user);
    }

    // --- reinitialize ---

    function test_Reinitialize_SeedsThrottleAndRoles() public {
        assertEq(psmV2.getMintThrottle().blockLimit, type(uint256).max);
        assertEq(psmV2.getMintThrottle().dailyLimit, type(uint256).max);
        assertEq(psmV2.getRedeemThrottle().blockLimit, type(uint256).max);
        assertEq(psmV2.getRedeemThrottle().dailyLimit, type(uint256).max);
        assertEq(psmV2.getRoleAdmin(LIMIT_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(psmV2.getRoleAdmin(THROTTLE_EXEMPT_ROLE), ADMIN_ROLE);
    }

    function test_Reinitialize_Revert_SecondCall() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        psmV2.reinitialize();
    }

    // --- min amounts ---

    function test_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        psmV2.setMinDeposit(10e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinDeposit.selector, 1e6, 10e6));
        psmV2.deposit(1e6, user1);
    }

    function test_Deposit_AtMinDeposit() public {
        vm.prank(limitManager);
        psmV2.setMinDeposit(10e6);
        assertGt(_deposit(user1, 10e6), 0);
    }

    function test_Redeem_Revert_UnderMinWithdraw() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);

        vm.prank(limitManager);
        psmV2.setMinWithdraw(10e6);

        // 1e18 shares redeem to 1e6 USDT0, below the 10e6 floor
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinWithdraw.selector, 1e6, 10e6));
        psmV2.redeem(1e18, user1, user1);
    }

    function test_Redeem_Revert_UnderMinWithdraw_AfterStakedFee() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);

        // The PSM owns the syzUSD shares during the inner redemption. Remove its fee exemption and
        // set a 1% instant fee so the PSM receives fee-reduced proceeds.
        vm.startPrank(admin);
        styzV3.grantRole(FEE_MANAGER_ROLE, admin);
        styzV3.revokeRole(REDEEM_FEE_EXEMPT_ROLE, address(psmV2));
        styzV3.setInstantRedeemFee(10_000); // 1%
        vm.stopPrank();

        vm.prank(limitManager);
        psmV2.setMinWithdraw(100e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinWithdraw.selector, 99_009_900, 100e6));
        psmV2.redeem(100e18, user1, user1);
    }

    function test_CreateRedeemOrder_Revert_UnderMinWithdraw() public {
        _deposit(user1, 100e6);

        vm.prank(limitManager);
        psmV2.setMinWithdraw(10e6);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinWithdraw.selector, 1e6, 10e6));
        psmV2.createRedeemOrder(1e18, user1, user1);

        vm.prank(user1);
        psmV2.createRedeemOrder(10e18, user1, user1); // at the floor, succeeds
    }

    function test_MaxDeposit_ClampsToZeroBelowMin() public {
        vm.prank(limitManager);
        psmV2.setMintThrottle(5e6, type(uint256).max);
        vm.prank(limitManager);
        psmV2.setMinDeposit(10e6);

        // Throttle headroom (5e6) is below the 10e6 floor
        assertEq(psmV2.maxDeposit(user1), 0);
    }

    function test_MaxRedeem_ClampsToZeroBelowMin() public {
        _deposit(user1, 100e6);
        vm.roll(block.number + 1);

        vm.prank(limitManager);
        psmV2.setRedeemThrottle(5e6, type(uint256).max);
        vm.prank(limitManager);
        psmV2.setMinWithdraw(10e6);

        assertEq(psmV2.maxRedeem(user1), 0);
    }

    // --- throttle ---

    function test_MintThrottle_BlocksOverBlockLimit() public {
        vm.prank(limitManager);
        psmV2.setMintThrottle(100e6, type(uint256).max);

        _deposit(user1, 100e6);

        // Same block, no headroom left
        assertEq(psmV2.maxDeposit(user1), 0);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxDeposit.selector, user2, 1e6, 0));
        psmV2.deposit(1e6, user2);
    }

    function test_MintThrottle_ResetsNextBlock() public {
        vm.prank(limitManager);
        psmV2.setMintThrottle(100e6, type(uint256).max);

        _deposit(user1, 100e6);
        vm.roll(block.number + 1);
        assertEq(psmV2.maxDeposit(user1), 100e6);
        assertGt(_deposit(user1, 100e6), 0);
    }

    function test_RedeemThrottle_BlocksOverBlockLimit() public {
        _deposit(user1, 1000e6);
        _deposit(user2, 1000e6);
        vm.roll(block.number + 1);

        vm.prank(limitManager);
        psmV2.setRedeemThrottle(100e6, type(uint256).max);

        // user1 drains the per-block budget (100e6 USDT0 = 100e18 shares)
        _redeem(user1, 100e18);
        assertEq(psmV2.maxRedeem(user2), 0);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(ExceededMaxRedeem.selector, user2, 1e18, 0));
        psmV2.redeem(1e18, user2, user2);
    }

    // --- exemptions ---

    function test_Exempt_BypassesMintThrottle() public {
        vm.prank(limitManager);
        psmV2.setMintThrottle(1e6, type(uint256).max);

        // Far above the 1e6 block limit, but exempt
        assertGt(_deposit(throttleExempt, 1000e6), 0);
    }

    // --- order path stays ungated ---

    function test_OrderPath_UnthrottledAndUnguarded() public {
        vm.prank(limitManager);
        psmV2.setRedeemThrottle(1, 1);

        // Mint and create a redeem order in the same block, with the throttle effectively closed:
        // the order path is neither throttled nor same-block guarded
        _deposit(user1, 100e6);
        vm.prank(user1);
        uint256 orderId = psmV2.createRedeemOrder(50e18, user1, user1);
        assertEq(uint256(psmV2.getRedeemOrder(orderId).shares), 50e18);
    }
}
