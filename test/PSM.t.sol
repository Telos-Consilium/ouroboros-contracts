// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Order, OrderStatus} from "../src/interfaces/IPSMDefinitions.sol";
import {IPSMDefinitions} from "../src/interfaces/IPSMDefinitions.sol";

import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";
import {StakedYuzuUSDV2} from "../src/StakedYuzuUSDV2.sol";
import {YuzuUSD} from "../src/YuzuUSD.sol";
import {PSM} from "../src/PSM.sol";

contract USDCMock is ERC20Mock {
    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract PSMTest is IPSMDefinitions, Test {
    USDCMock public asset;
    StakedYuzuUSDV2 public styz;
    YuzuUSD public yzusd;
    PSM public psm;

    address public admin;
    address public treasury;
    address public feeReceiver;
    address public orderFiller;
    address public liquidityManager;
    address public restrictionManager;
    address public user1;
    address public user2;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 internal constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");

    bytes32 internal constant USER_ROLE = keccak256("USER_ROLE");

    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");

    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function setUp() public virtual {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        feeReceiver = makeAddr("feeReceiver");
        orderFiller = makeAddr("orderFiller");
        liquidityManager = makeAddr("liquidityManager");
        restrictionManager = makeAddr("restrictionManager");

        Vm.Wallet memory user1Wallet = vm.createWallet("user1");
        user1 = user1Wallet.addr;

        Vm.Wallet memory user2Wallet = vm.createWallet("user2");
        user2 = user2Wallet.addr;

        // Deploy mock asset and mint balances
        asset = new USDCMock();
        asset.mint(user1, 10_000_000e6);
        asset.mint(user2, 10_000_000e6);
        asset.mint(orderFiller, 10_000_000e6);
        asset.mint(liquidityManager, 10_000_000e6);

        _setupYuzuUSD();
        _setupStakedYuzuUSDV2();
        _setupPSM();

        // Register PSM as a syzUSD integration and a yzUSD minter, redeemer, and redeem manager
        vm.startPrank(admin);
        styz.setIntegration(address(psm), true, true);
        yzusd.grantRole(MINTER_ROLE, address(psm));
        yzusd.grantRole(REDEEMER_ROLE, address(psm));
        yzusd.grantRole(REDEEM_MANAGER_ROLE, address(psm));
        vm.stopPrank();

        // Label contracts
        vm.label(address(yzusd), "Yuzu USD (proxy)");
        vm.label(address(styz), "Staked Yuzu USD (proxy)");
        vm.label(address(psm), "PSM (proxy)");

        // Approve assets to PSM
        _approveAssets(user1, address(psm), type(uint256).max);
        _approveAssets(user2, address(psm), type(uint256).max);
        _approveAssets(orderFiller, address(psm), type(uint256).max);
        _approveAssets(liquidityManager, address(psm), type(uint256).max);
    }

    function _setupYuzuUSD() internal {
        YuzuUSD implementation = new YuzuUSD();
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
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        yzusd = YuzuUSD(address(proxy));

        // Set redeem fee > 0
        vm.startPrank(admin);
        yzusd.grantRole(RESTRICTION_MANAGER_ROLE, admin);
        yzusd.grantRole(MINTER_ROLE, user1);
        yzusd.grantRole(REDEEMER_ROLE, user1);
        yzusd.grantRole(MINTER_ROLE, user2);
        yzusd.grantRole(REDEEMER_ROLE, user2);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.setRedeemFee(1e3);
        vm.stopPrank();
    }

    function _setupStakedYuzuUSDV2() internal {
        StakedYuzuUSDV2 implementation = new StakedYuzuUSDV2();
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(address(yzusd)),
            "Staked Yuzu USD",
            "syzUSD",
            admin,
            feeReceiver,
            1 days
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        styz = StakedYuzuUSDV2(address(proxy));

        // Set redeem fee > 0
        vm.prank(admin);
        styz.setRedeemFee(1e3);
    }

    function _setupPSM() internal {
        PSM implementation = new PSM();
        bytes memory initData = abi.encodeWithSelector(PSM.initialize.selector, asset, yzusd, styz, admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        psm = PSM(address(proxy));

        vm.startPrank(admin);
        psm.grantRole(ORDER_FILLER_ROLE, orderFiller);
        psm.grantRole(LIQUIDITY_MANAGER_ROLE, liquidityManager);
        psm.grantRole(RESTRICTION_MANAGER_ROLE, restrictionManager);
        vm.stopPrank();

        vm.startPrank(restrictionManager);
        psm.grantRole(USER_ROLE, user1);
        psm.grantRole(USER_ROLE, user2);
        vm.stopPrank();
    }

    // Helpers
    function _approveAssets(address _owner, address spender, uint256 amount) internal {
        vm.prank(_owner);
        asset.approve(spender, amount);
    }

    function _approveStaked(address _owner, address spender, uint256 amount) internal {
        vm.prank(_owner);
        styz.approve(spender, amount);
    }

    function _depositLiquidity(uint256 amount) internal {
        vm.prank(liquidityManager);
        psm.depositLiquidity(amount);
    }

    function _asArray(uint256 orderId) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = orderId;
    }

    // Initialization
    function test_Initialize() public {
        assertEq(psm.asset(), address(asset));
        assertEq(psm.vault0(), address(yzusd));
        assertEq(psm.vault1(), address(styz));
        assertEq(psm.orderCount(), 0);
        assertEq(psm.pendingOrderCount(), 0);
        assertEq(psm.getPendingOrderIds(0, type(uint256).max).length, 0);

        assertEq(psm.getRoleAdmin(ADMIN_ROLE), psm.DEFAULT_ADMIN_ROLE());
        assertEq(psm.getRoleAdmin(ORDER_FILLER_ROLE), ADMIN_ROLE);
        assertEq(psm.getRoleAdmin(LIQUIDITY_MANAGER_ROLE), ADMIN_ROLE);
        assertEq(psm.getRoleAdmin(RESTRICTION_MANAGER_ROLE), ADMIN_ROLE);

        assertTrue(psm.hasRole(psm.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(psm.hasRole(ADMIN_ROLE, admin));
    }

    function test_Preview() public {
        uint256 assets = 1e6;
        uint256 shares = 1e18;

        assertEq(psm.previewDeposit(assets), shares);
        assertEq(psm.previewRedeem(shares), assets);

        _approveAssets(user1, address(yzusd), assets);

        vm.startPrank(user1);
        uint256 yzusdMinted = yzusd.deposit(assets, user1);
        yzusd.approve(address(styz), yzusdMinted / 2);
        uint256 styzMinted = styz.deposit(yzusdMinted / 2, user1);
        yzusd.transfer(address(styz), yzusdMinted / 2);
        vm.stopPrank();

        assertEq(
            psm.previewDeposit(assets), Math.mulDiv(yzusdMinted, styzMinted + 1, yzusdMinted + 1, Math.Rounding.Floor)
        );
        assertEq(
            psm.previewRedeem(shares), Math.mulDiv(shares, yzusdMinted + 1, styzMinted + 1, Math.Rounding.Floor) / 1e12
        );
    }

    function test_Deposit() public {
        uint256 assets = 1e6;
        uint256 expectedShares = 1e18;
        vm.prank(user1);
        vm.expectEmit();
        emit Deposit(user1, user1, assets, expectedShares);
        uint256 shares = psm.deposit(assets, user1);
        assertEq(shares, expectedShares);
        assertEq(styz.balanceOf(user1), expectedShares);
        assertEq(asset.balanceOf(feeReceiver), 0);
    }

    function test_Redeem() public {
        uint256 shares1 = 1e18;
        uint256 expectedShares0 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);

        _approveStaked(user1, address(psm), shares1);
        _depositLiquidity(expectedAssets);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true, address(styz));
        emit Withdraw(address(psm), address(psm), user1, expectedShares0, shares1);
        vm.expectEmit(true, true, true, true, address(yzusd));
        emit Withdraw(address(psm), user1, address(psm), expectedAssets, expectedShares0);
        vm.expectEmit(true, true, true, true, address(psm));
        emit Withdraw(user1, user1, user1, expectedAssets, shares1);

        uint256 assets = psm.redeem(shares1, user1);
        assertEq(assets, expectedAssets);
        assertEq(styz.balanceOf(user1), 0);
        assertEq(asset.balanceOf(feeReceiver), 0);
    }

    function test_Redeem_Revert_InsufficientLiquidity() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        asset.mint(address(yzusd), 10e6);

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);

        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(psm), 0, expectedAssets)
        );
        psm.redeem(shares1, user1);
    }

    function test_CreateRedeemOrder() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);

        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        uint256 orderId = psm.createRedeemOrder(shares1, user1);

        Order memory order = psm.getRedeemOrder(orderId);
        assertEq(order.owner, user1);
        assertEq(order.receiver, user1);
        assertEq(order.shares, shares1);
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
        assertEq(psm.pendingOrderCount(), 1);
    }

    function test_CreateRedeemOrder_Revert_ZeroReceiver() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);
        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        vm.expectRevert(InvalidZeroAddress.selector);
        psm.createRedeemOrder(shares1, address(0));
    }

    function test_FillRedeemOrders() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);
        _approveStaked(user1, address(psm), shares1);

        uint256 balanceBefore = asset.balanceOf(user1);

        vm.prank(user1);
        uint256 orderId = psm.createRedeemOrder(shares1, user1);

        _depositLiquidity(expectedAssets);

        vm.prank(orderFiller);
        psm.fillRedeemOrders(expectedAssets, _asArray(orderId));

        Order memory order = psm.getRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
        assertEq(psm.pendingOrderCount(), 0);
        assertEq(asset.balanceOf(user1), balanceBefore + expectedAssets);
    }

    function test_FillRedeemOrders_Revert_OrderNotPending() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);
        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        uint256 orderId = psm.createRedeemOrder(shares1, user1);

        _depositLiquidity(expectedAssets);

        vm.prank(orderFiller);
        psm.fillRedeemOrders(expectedAssets, _asArray(orderId));

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        psm.fillRedeemOrders(expectedAssets, _asArray(orderId));
    }

    function test_CancelRedeemOrders() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);
        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        uint256 orderId = psm.createRedeemOrder(shares1, user1);

        vm.prank(orderFiller);
        psm.cancelRedeemOrders(_asArray(orderId));

        Order memory order = psm.getRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Cancelled));
        assertEq(psm.pendingOrderCount(), 0);
        assertEq(styz.balanceOf(user1), shares1);
    }

    function test_CancelRedeemOrders_Revert_OrderNotPending() public {
        uint256 shares1 = 1e18;
        uint256 expectedAssets = 1e6;

        vm.prank(user1);
        psm.deposit(expectedAssets, user1);
        _approveStaked(user1, address(psm), shares1);

        vm.prank(user1);
        uint256 orderId = psm.createRedeemOrder(shares1, user1);

        vm.prank(orderFiller);
        psm.cancelRedeemOrders(_asArray(orderId));

        vm.prank(orderFiller);
        vm.expectRevert(abi.encodeWithSelector(OrderNotPending.selector, orderId));
        psm.cancelRedeemOrders(_asArray(orderId));
    }

    function test_DepositLiquidity() public {
        uint256 amount = 1e6;
        uint256 initialBalance = asset.balanceOf(address(psm));

        vm.prank(liquidityManager);
        vm.expectEmit();
        emit DepositedLiquidity(liquidityManager, amount);
        psm.depositLiquidity(amount);

        assertEq(asset.balanceOf(address(psm)) - initialBalance, amount);
    }

    function test_WithdrawLiquidity() public {
        uint256 amount = 1e6;
        _depositLiquidity(amount);

        uint256 receiverBalanceBefore = asset.balanceOf(user1);

        vm.prank(liquidityManager);
        vm.expectEmit();
        emit WithdrewLiquidity(user1, amount);
        psm.withdrawLiquidity(amount, user1);

        assertEq(asset.balanceOf(user1) - receiverBalanceBefore, amount);
    }

    function test_GetPendingOrderIds() public {
        uint256 shares1 = 1e18;
        uint256 shares2 = 2e18;
        uint256 shares3 = 3e18;

        vm.prank(user1);
        psm.deposit(1e6, user1);
        _approveStaked(user1, address(psm), shares1);
        vm.prank(user1);
        uint256 orderId1 = psm.createRedeemOrder(shares1, user1);

        vm.prank(user2);
        psm.deposit(2e6, user2);
        _approveStaked(user2, address(psm), shares2);
        vm.prank(user2);
        uint256 orderId2 = psm.createRedeemOrder(shares2, user2);

        vm.prank(user1);
        psm.deposit(3e6, user1);
        _approveStaked(user1, address(psm), shares3);
        vm.prank(user1);
        uint256 orderId3 = psm.createRedeemOrder(shares3, user1);

        uint256[] memory allIds = psm.getPendingOrderIds(0, type(uint256).max);
        assertEq(allIds.length, 3);
        assertEq(allIds[0], orderId1);
        assertEq(allIds[1], orderId2);
        assertEq(allIds[2], orderId3);

        uint256[] memory firstId = psm.getPendingOrderIds(0, 1);
        assertEq(firstId.length, 1);
        assertEq(firstId[0], orderId1);

        uint256[] memory midIds = psm.getPendingOrderIds(1, 2);
        assertEq(midIds.length, 2);
        assertEq(midIds[0], orderId2);
        assertEq(midIds[1], orderId3);

        // Cancel the middle order and confirm pagination skips it
        vm.prank(orderFiller);
        psm.cancelRedeemOrders(_asArray(orderId2));

        uint256[] memory afterCancel = psm.getPendingOrderIds(0, type(uint256).max);
        assertEq(afterCancel.length, 2);
        assertEq(afterCancel[0], orderId1);
        assertEq(afterCancel[1], orderId3);

        uint256[] memory lastId = psm.getPendingOrderIds(1, 1);
        assertEq(lastId.length, 1);
        assertEq(lastId[0], orderId3);
    }

    function test_Deposit_Revert_NotUser() public {
        uint256 assets = 1e6;
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), USER_ROLE)
        );
        psm.deposit(assets, user1);
    }

    function test_Redeem_Revert_NotUser() public {
        uint256 shares1 = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), USER_ROLE)
        );
        psm.redeem(shares1, user1);
    }

    function test_CreateRedeemOrder_Revert_NotUser() public {
        uint256 shares1 = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), USER_ROLE)
        );
        psm.createRedeemOrder(shares1, user1);
    }

    function test_FillRedeemOrders_Revert_NotFiller() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ORDER_FILLER_ROLE)
        );
        psm.fillRedeemOrders(0, _asArray(0));
    }

    function test_CancelRedeemOrders_Revert_NotFiller() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ORDER_FILLER_ROLE)
        );
        psm.cancelRedeemOrders(_asArray(0));
    }

    function test_DepositLiquidity_Revert_NotLiquidityManager() public {
        uint256 amount = 1e6;
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIQUIDITY_MANAGER_ROLE
            )
        );
        psm.depositLiquidity(amount);
    }

    function test_WithdrawLiquidity_Revert_NotLiquidityManager() public {
        uint256 amount = 1e6;
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user1, LIQUIDITY_MANAGER_ROLE
            )
        );
        psm.withdrawLiquidity(amount, user1);
    }
}
