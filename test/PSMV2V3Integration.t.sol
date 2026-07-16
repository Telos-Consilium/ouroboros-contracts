// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../src/YuzuUSDV3Facet.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV3} from "../src/StakedYuzuUSDV3.sol";
import {PSM} from "../src/PSM.sol";
import {PSMV2} from "../src/PSMV2.sol";
import {IPSMDefinitions} from "../src/interfaces/IPSMDefinitions.sol";
import {UpgradeTestBase} from "./helpers/UpgradeTestBase.sol";
import {
    BURNER_ROLE,
    DELAY_EXEMPT_ROLE,
    LIQUIDITY_MANAGER_ROLE,
    MINTER_ROLE,
    ORDER_FILLER_ROLE,
    PAUSE_MANAGER_ROLE,
    REDEEMER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    RESTRICTION_MANAGER_ROLE,
    USER_ROLE
} from "./helpers/TestRoles.sol";

contract PSMV2V3USDT0Mock is ERC20Mock {
    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }
}

contract PSMV2V3IntegrationTest is UpgradeTestBase {
    PSMV2V3USDT0Mock internal asset;
    YuzuUSDV3 internal yzusd;
    StakedYuzuUSDV3 internal styz;
    PSMV2 internal psm;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal user = makeAddr("user");
    address internal liquidityManager = makeAddr("liquidityManager");
    address internal restrictionManager = makeAddr("restrictionManager");

    function setUp() public {
        asset = new PSMV2V3USDT0Mock();
        asset.mint(user, 10_000_000e6);
        asset.mint(liquidityManager, 10_000_000e6);

        yzusd = _deployYuzuUSDV3();
        styz = _deployStakedYuzuUSDV3();
        psm = _deployPSMV2();

        vm.startPrank(admin);
        yzusd.grantRole(RESTRICTION_MANAGER_ROLE, admin);
        yzusd.grantRole(MINTER_ROLE, address(psm));
        yzusd.grantRole(REDEEMER_ROLE, address(psm));
        yzusd.grantRole(BURNER_ROLE, address(psm));
        styz.grantRole(DELAY_EXEMPT_ROLE, address(psm));
        styz.grantRole(REDEEM_FEE_EXEMPT_ROLE, address(psm));
        psm.grantRole(LIQUIDITY_MANAGER_ROLE, liquidityManager);
        psm.grantRole(RESTRICTION_MANAGER_ROLE, restrictionManager);
        vm.stopPrank();

        vm.prank(restrictionManager);
        psm.grantRole(USER_ROLE, user);

        vm.prank(user);
        asset.approve(address(psm), type(uint256).max);
        vm.prank(user);
        styz.approve(address(psm), type(uint256).max);
        vm.prank(liquidityManager);
        asset.approve(address(psm), type(uint256).max);

        vm.prank(liquidityManager);
        psm.depositLiquidity(1_000_000e6);
    }

    function test_DepositAndRedeem_ComposesWithV3Vaults() public {
        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);

        assertEq(shares, 100e18);
        assertEq(styz.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(address(psm)), 1_000_000e6);

        vm.roll(block.number + 1);
        uint256 balanceBefore = asset.balanceOf(user);

        vm.prank(user);
        uint256 assetsOut = psm.redeem(shares, user, user);

        assertEq(assetsOut, 100e6);
        assertEq(asset.balanceOf(user) - balanceBefore, 100e6);
        assertEq(styz.balanceOf(user), 0);
        assertEq(asset.balanceOf(address(psm)), 999_900e6);
        // The PSM interposes as the vault principal but holds no shares afterwards
        assertEq(styz.balanceOf(address(psm)), 0);
    }

    function test_Redeem_PullsSharesViaAllowance() public {
        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);
        assertEq(styz.balanceOf(address(psm)), 0);

        vm.roll(block.number + 1);

        // An exact approval is consumed by the pull, and the PSM keeps no shares
        vm.prank(user);
        styz.approve(address(psm), shares);
        vm.prank(user);
        psm.redeem(shares, user, user);

        assertEq(styz.allowance(user, address(psm)), 0);
        assertEq(styz.balanceOf(address(psm)), 0);
        assertEq(styz.balanceOf(user), 0);
    }

    function test_OrderPath_FillRedeemsFromEscrow() public {
        vm.prank(admin);
        psm.grantRole(ORDER_FILLER_ROLE, liquidityManager);

        vm.prank(user);
        psm.deposit(100e6, user);
        vm.roll(block.number + 1);

        vm.prank(user);
        uint256 orderId = psm.createRedeemOrder(100e18, user, user);
        // Shares sit in the PSM's escrow while the order is pending, so the fill redeems as the
        // principal without pulling again
        assertEq(styz.balanceOf(address(psm)), 100e18);
        assertEq(styz.balanceOf(user), 0);

        uint256 balanceBefore = asset.balanceOf(user);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        vm.prank(liquidityManager);
        psm.fillRedeemOrders(0, ids);

        assertEq(asset.balanceOf(user) - balanceBefore, 100e6);
        assertEq(styz.balanceOf(address(psm)), 0);
    }

    function test_SameBlock_OuterOwnerRestricted() public {
        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);

        assertEq(styz.currentBlockRestrictedBalance(user), shares);
        assertEq(psm.maxRedeem(user), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IPSMDefinitions.ExceededMaxRedeem.selector, user, shares, 0));
        psm.redeem(shares, user, user);

        // The failed redeem leaves the owner's shares and allowance intact.
        assertEq(styz.balanceOf(user), shares);
    }

    function test_SameBlock_TransferHopBypass_Closed() public {
        address user2 = makeAddr("user2");
        vm.prank(restrictionManager);
        psm.grantRole(USER_ROLE, user2);
        vm.prank(user2);
        styz.approve(address(psm), type(uint256).max);

        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);
        vm.prank(user);
        styz.transfer(user2, shares);

        assertEq(styz.currentBlockRestrictedBalance(user2), shares);
        assertEq(psm.maxRedeem(user2), 0);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IPSMDefinitions.ExceededMaxRedeem.selector, user2, shares, 0));
        psm.redeem(shares, user2, user2);
    }

    function test_SameBlock_DustReceipt_PreservesMatureRedeem() public {
        // user holds a mature position from an earlier block.
        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);
        vm.roll(block.number + 1);

        // A fresh dust deposit routed to user restricts only the dust shares, not the mature balance.
        vm.prank(user);
        uint256 dustShares = psm.deposit(1, user);
        assertEq(styz.currentBlockRestrictedBalance(user), dustShares);
        assertEq(psm.maxRedeem(user), shares);

        vm.prank(user);
        uint256 assetsOut = psm.redeem(shares, user, user);
        assertGt(assetsOut, 0);
    }

    function test_SameBlock_MaturesNextBlock() public {
        vm.prank(user);
        uint256 shares = psm.deposit(100e6, user);
        vm.roll(block.number + 1);

        assertEq(styz.currentBlockRestrictedBalance(user), 0);
        vm.prank(user);
        assertGt(psm.redeem(shares, user, user), 0);
    }

    function _deployYuzuUSDV3() internal returns (YuzuUSDV3 deployed) {
        address impl = address(new YuzuUSDV3(address(new YuzuUSDV3Facet())));
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            address(asset),
            "Yuzu USD",
            "yzUSD",
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        deployed = YuzuUSDV3(address(new ERC1967Proxy(impl, initData)));
        deployed.reinitialize();
    }

    function _deployStakedYuzuUSDV3() internal returns (StakedYuzuUSDV3 deployed) {
        address v1Impl = address(new StakedYuzuUSD());
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "syzUSD",
            owner,
            feeReceiver,
            1 days
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(v1Impl, owner, initData);
        ProxyAdmin proxyAdmin = _proxyAdmin(address(proxy));

        vm.prank(owner);
        StakedYuzuUSD(address(proxy)).pause();

        address v3Impl = address(new StakedYuzuUSDV3());
        vm.prank(owner);
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

    function _deployPSMV2() internal returns (PSMV2 deployed) {
        address impl = address(new PSMV2());
        bytes memory initData = abi.encodeWithSelector(
            PSM.initialize.selector, IERC20(address(asset)), IERC4626(address(yzusd)), IERC4626(address(styz)), admin, 0
        );
        deployed = PSMV2(address(new ERC1967Proxy(impl, initData)));
        deployed.reinitialize();
    }
}
