// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {YuzuUSDMinter} from "../src/YuzuUSDMinter.sol";
import {YuzuUSD} from "../src/YuzuUSD.sol";
import {Order, OrderStatus} from "../src/interfaces/IYuzuUSDMinter.sol";
import {IYuzuUSDMinterDefinitions} from "../src/interfaces/IYuzuUSDMinterDefinitions.sol";

contract YuzuUSDMinterTest is IYuzuUSDMinterDefinitions, Test {
    YuzuUSDMinter public minter;
    YuzuUSD public yzusd;
    ERC20Mock public collateralToken;

    address public admin;
    address public treasury;
    address public redeemFeeRecipient;
    address public orderFiller;
    address public limitManager;
    address public redeemManager;
    address public nonAdmin;
    address public user1;
    address public user2;

    uint256 public constant MAX_MINT_PER_BLOCK = 1000e18;
    uint256 public constant MAX_REDEEM_PER_BLOCK = 500e18;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        redeemFeeRecipient = makeAddr("redeemFeeRecipient");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        orderFiller = makeAddr("orderFiller");
        limitManager = makeAddr("limitManager");
        redeemManager = makeAddr("redeemManager");
        nonAdmin = makeAddr("nonAdmin");

        // Deploy YuzuUSD implementation and proxy
        yzusd = new YuzuUSD("Yuzu USD", "yzUSD", admin);

        collateralToken = new ERC20Mock();

        // Deploy YuzuUSDMinter implementation and proxy
        YuzuUSDMinter minterImplementation = new YuzuUSDMinter();
        bytes memory minterInitData = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(yzusd),
            address(collateralToken),
            admin,
            treasury,
            redeemFeeRecipient,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        ERC1967Proxy minterProxy = new ERC1967Proxy(address(minterImplementation), minterInitData);
        minter = YuzuUSDMinter(address(minterProxy));

        vm.startPrank(admin);

        // Set the minter contract as the minter for YuzuUSD
        yzusd.setMinter(address(minter));

        // Grant order filler role
        minter.grantRole(ORDER_FILLER_ROLE, orderFiller);
        minter.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        minter.grantRole(REDEEM_MANAGER_ROLE, redeemManager);

        vm.stopPrank();

        // Mint some collateral tokens to users for testing
        collateralToken.mint(user1, 10_000e18);
        collateralToken.mint(user2, 10_000e18);
        collateralToken.mint(orderFiller, 10_000e18);

        vm.startPrank(orderFiller);
        yzusd.approve(address(minter), type(uint256).max);
        collateralToken.approve(address(minter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user1);
        yzusd.approve(address(minter), type(uint256).max);
        collateralToken.approve(address(minter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        yzusd.approve(address(minter), type(uint256).max);
        collateralToken.approve(address(minter), type(uint256).max);
        vm.stopPrank();
    }

    // Initialization
    function test_Initialize() public view {
        assertEq(address(minter.yzusd()), address(yzusd));
        assertEq(minter.collateralToken(), address(collateralToken));
        assertEq(minter.treasury(), treasury);
        assertEq(minter.redeemFeeRecipient(), redeemFeeRecipient);
        assertEq(minter.maxMintPerBlock(), MAX_MINT_PER_BLOCK);
        assertEq(minter.maxRedeemPerBlock(), MAX_REDEEM_PER_BLOCK);
        assertEq(minter.instantRedeemFeePpm(), 0);
        assertEq(minter.fastRedeemFeePpm(), 0);
        assertEq(minter.standardRedeemFeePpm(), 0);
        assertEq(minter.fastFillWindow(), 1 days);
        assertEq(minter.standardRedeemDelay(), 7 days);
        assertTrue(minter.hasRole(ADMIN_ROLE, admin));
    }

    function test_Initialize_RevertInvalidZeroAddress() public {
        YuzuUSDMinter newImplementation = new YuzuUSDMinter();

        // Test invalid yzusd address
        vm.expectRevert(InvalidZeroAddress.selector);
        bytes memory initData1 = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(0),
            address(collateralToken),
            admin,
            treasury,
            redeemFeeRecipient,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        new ERC1967Proxy(address(newImplementation), initData1);

        // Test invalid collateral token address
        vm.expectRevert(InvalidZeroAddress.selector);
        bytes memory initData2 = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(yzusd),
            address(0),
            admin,
            treasury,
            redeemFeeRecipient,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        new ERC1967Proxy(address(newImplementation), initData2);

        // Test invalid admin address
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        bytes memory initData3 = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(yzusd),
            address(collateralToken),
            address(0),
            treasury,
            redeemFeeRecipient,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        new ERC1967Proxy(address(newImplementation), initData3);

        // Test invalid treasury address
        vm.expectRevert(InvalidZeroAddress.selector);
        bytes memory initData4 = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(yzusd),
            address(collateralToken),
            admin,
            address(0),
            redeemFeeRecipient,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        new ERC1967Proxy(address(newImplementation), initData4);

        // Test invalid redeem fee recipient address
        vm.expectRevert(InvalidZeroAddress.selector);
        bytes memory initData5 = abi.encodeWithSelector(
            YuzuUSDMinter.initialize.selector,
            address(yzusd),
            address(collateralToken),
            admin,
            treasury,
            address(0),
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
        new ERC1967Proxy(address(newImplementation), initData5);
    }

    // Admin Functions
    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit();
        emit TreasuryUpdated(treasury, newTreasury);
        vm.prank(admin);
        minter.setTreasury(newTreasury);

        assertEq(minter.treasury(), newTreasury);
    }

    function test_SetTreasury_OnlyAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setTreasury(makeAddr("newTreasury"));
    }

    function test_SetRedeemFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.expectEmit();
        emit RedeemFeeRecipientUpdated(redeemFeeRecipient, newRecipient);
        vm.prank(redeemManager);
        minter.setRedeemFeeRecipient(newRecipient);

        assertEq(minter.redeemFeeRecipient(), newRecipient);
    }

    function test_SetRedeemFeeRecipient_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setRedeemFeeRecipient(makeAddr("newRecipient"));
    }

    function test_SetMaxMintPerBlock() public {
        uint256 newMaxMint = 2000e18;

        vm.expectEmit();
        emit MaxMintPerBlockUpdated(MAX_MINT_PER_BLOCK, newMaxMint);
        vm.prank(limitManager);
        minter.setMaxMintPerBlock(newMaxMint);

        assertEq(minter.maxMintPerBlock(), newMaxMint);
    }

    function test_SetMaxMintPerBlock_OnlyLimitManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxMintPerBlock(2000e18);
    }

    function test_SetMaxRedeemPerBlock() public {
        uint256 newMaxRedeem = 1000e18;

        vm.expectEmit();
        emit MaxRedeemPerBlockUpdated(MAX_REDEEM_PER_BLOCK, newMaxRedeem);
        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(newMaxRedeem);

        assertEq(minter.maxRedeemPerBlock(), newMaxRedeem);
    }

    function test_SetMaxRedeemPerBlock_OnlyLimitManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxRedeemPerBlock(1000e18);
    }

    function test_SetInstantRedeemFeePpm() public {
        uint256 newFee = 5_000; // 0.5%

        vm.expectEmit();
        emit InstantRedeemFeePpmUpdated(0, newFee);
        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(newFee);

        assertEq(minter.instantRedeemFeePpm(), newFee);
    }

    function test_SetInstantRedeemFeePpm_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setInstantRedeemFeePpm(5_000);
    }

    function test_SetFastRedeemFeePpm() public {
        uint256 newFee = 2_500; // 0.25%

        vm.expectEmit();
        emit FastRedeemFeePpmUpdated(0, newFee);
        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(newFee);

        assertEq(minter.fastRedeemFeePpm(), newFee);
    }

    function test_SetFastRedeemFeePpm_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setFastRedeemFeePpm(2_500);
    }

    function test_SetStandardRedeemFeePpm() public {
        uint256 newFee = 1_000; // 0.1%

        vm.expectEmit();
        emit StandardRedeemFeePpmUpdated(0, newFee);
        vm.prank(redeemManager);
        minter.setStandardRedeemFeePpm(newFee);

        assertEq(minter.standardRedeemFeePpm(), newFee);
    }

    function test_SetStandardRedeemFeePpm_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setStandardRedeemFeePpm(1_000);
    }

    function test_SetFastFillWindow() public {
        uint256 newWindow = 2 days;

        vm.expectEmit();
        emit FastFillWindowUpdated(1 days, newWindow);
        vm.prank(redeemManager);
        minter.setFastFillWindow(newWindow);

        assertEq(minter.fastFillWindow(), newWindow);
    }

    function test_SetFastFillWindow_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setFastFillWindow(2 days);
    }

    function test_SetStandardRedeemDelay() public {
        uint256 newDelay = 14 days;

        vm.expectEmit();
        emit StandardRedeemDelayUpdated(7 days, newDelay);
        vm.prank(redeemManager);
        minter.setStandardRedeemDelay(newDelay);

        assertEq(minter.standardRedeemDelay(), newDelay);
    }

    function test_SetStandardRedeemDelay_OnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setStandardRedeemDelay(14 days);
    }

    function test_WithdrawCollateral() public {
        uint256 amount = 100e18;
        address to = makeAddr("recipient");

        collateralToken.mint(address(minter), amount);

        vm.expectEmit();
        emit CollateralWithdrawn(to, amount);
        vm.prank(admin);
        minter.withdrawCollateral(to, amount);

        assertEq(collateralToken.balanceOf(to), amount);
    }

    function test_RescueTokens() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 100e18;
        otherToken.mint(address(minter), amount);
        uint256 balanceBefore = otherToken.balanceOf(user1);
        vm.prank(admin);
        minter.rescueTokens(address(otherToken), user1, amount);
        assertEq(otherToken.balanceOf(user1), balanceBefore + amount);
    }

    function test_RescueTokens_RevertOnlyOwner() public {
        ERC20Mock otherToken = new ERC20Mock();
        uint256 amount = 100e18;
        otherToken.mint(address(minter), amount);
        vm.expectRevert();
        vm.prank(user1);
        minter.rescueTokens(address(otherToken), user1, amount);
    }

    function test_RescueTokens_YzUSD() public {
        uint256 amount = 100e18;
        vm.prank(address(minter));
        yzusd.mint(address(minter), amount);
        uint256 balanceBefore = yzusd.balanceOf(user1);
        vm.prank(admin);
        minter.rescueTokens(address(yzusd), user1, amount);
        assertEq(yzusd.balanceOf(user1), balanceBefore + amount);
    }

    function test_RescueTokens_YzUSD_RevertInsufficientOutstandingBalance() public {
        uint256 amount = 100e18;
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutstandingBalance.selector, amount, 0));
        vm.prank(admin);
        minter.rescueTokens(address(yzusd), user1, amount);
    }

    function test_RescueTokens_RevertUnderlyingToken() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(collateralToken)));
        vm.prank(admin);
        minter.rescueTokens(address(collateralToken), user1, 100e18);
    }

    // Mint
    function test_Mint() public {
        uint256 amount = 100e18;

        vm.expectEmit();
        emit Minted(user1, user1, amount);
        vm.prank(user1);
        minter.mint(user1, amount);

        assertEq(yzusd.balanceOf(user1), amount);
        assertEq(collateralToken.balanceOf(treasury), amount);
        assertEq(minter.mintedPerBlock(block.number), amount);
    }

    function test_Mint_RevertInvalidZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidZeroAmount.selector));
        vm.prank(user1);
        minter.mint(user1, 0);
    }

    function test_Mint_RevertLimitExceeded() public {
        uint256 amount = MAX_MINT_PER_BLOCK + 1;

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, amount, MAX_MINT_PER_BLOCK));
        vm.prank(user1);
        minter.mint(user1, amount);
    }

    function test_Mint_ZeroLimit_RevertLimitExceeded() public {
        uint256 amount = 100e18;

        vm.prank(limitManager);
        minter.setMaxMintPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, amount, 0));
        vm.prank(user1);
        minter.mint(user1, amount);
    }

    // Instant Redeem Tests
    function test_InstantRedeem() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(user1);
        minter.instantRedeem(user1, redeemAmount);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount);
        assertEq(collateralToken.balanceOf(address(minter)), mintAmount - redeemAmount);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount);
    }

    function test_InstantRedeem_WithFee() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 feePpm = 10_000; // 1%
        uint256 expectedFee = (redeemAmount * feePpm) / 1_000_000;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(feePpm);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount, expectedFee);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(user1);
        minter.instantRedeem(user1, redeemAmount);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount - expectedFee);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);
        assertEq(collateralToken.balanceOf(address(minter)), mintAmount - redeemAmount);
        assertEq(yzusd.balanceOf(user1), mintAmount - redeemAmount);
    }

    function test_InstantRedeem_RevertLimitExceeded() public {
        uint256 amount = MAX_REDEEM_PER_BLOCK + 1;

        collateralToken.mint(address(minter), amount);
        vm.prank(address(minter));
        yzusd.mint(user1, amount);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, amount, MAX_REDEEM_PER_BLOCK));
        vm.prank(user1);
        minter.instantRedeem(user1, amount);
    }

    function test_InstantRedeem_ZeroLimit_RevertLimitExceeded() public {
        uint256 amount = MAX_REDEEM_PER_BLOCK + 1;

        collateralToken.mint(address(minter), amount);
        vm.prank(address(minter));
        yzusd.mint(user1, amount);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, amount, 0));
        vm.prank(user1);
        minter.instantRedeem(user1, amount);
    }

    function test_InstantRedeem_RevertInsufficientFunds() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.startPrank(user1);
        yzusd.burn(yzusd.balanceOf(user1));
        vm.expectRevert();
        minter.instantRedeem(user1, redeemAmount);
        vm.stopPrank();
    }

    function test_InstantRedeem_RevertLiquidityBufferExceeded() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.expectRevert(abi.encodeWithSelector(LiquidityBufferExceeded.selector, redeemAmount, 0));
        vm.prank(user1);
        minter.instantRedeem(user1, redeemAmount);
    }

    // Fast Redeem Tests
    function test_CreateFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.expectEmit();
        emit FastRedeemOrderCreated(0, user1, redeemAmount);
        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore);
        assertEq(collateralToken.balanceOf(address(minter)), 0);
        assertEq(minter.redeemedPerBlock(block.number), 0);
        assertEq(minter.currentPendingFastRedeemValue(), redeemAmount);
        assertEq(minter.fastRedeemOrderCount(), 1);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(order.amount, redeemAmount);
        assertEq(order.owner, user1);
        assertEq(order.feePpm, 0);
        assertEq(order.dueTime, block.timestamp + minter.fastFillWindow());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_FillFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.expectEmit();
        emit FastRedeemOrderFilled(orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillFastRedeemOrder_WithFee() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 feePpm = 10_000; // 1%
        uint256 expectedFee = (redeemAmount * feePpm) / 1_000_000;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(feePpm);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.expectEmit();
        emit FastRedeemOrderFilled(orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount, expectedFee);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount - expectedFee);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillFastRedeemOrder_PastDueTime() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.warp(block.timestamp + minter.fastFillWindow());

        vm.expectEmit();
        emit FastRedeemOrderFilled(orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_CancelFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.warp(block.timestamp + minter.fastFillWindow());

        vm.expectEmit();
        emit IYuzuUSDMinterDefinitions.FastRedeemOrderCancelled(orderId);
        vm.prank(user1);
        minter.cancelFastRedeemOrder(orderId);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Cancelled));
        assertEq(minter.currentPendingFastRedeemValue(), orderId);
    }

    function test_CancelFastRedeemOrder_RevertNotOwner() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.warp(block.timestamp + minter.fastFillWindow());

        vm.expectRevert();
        vm.prank(user2);
        minter.cancelFastRedeemOrder(orderId);
    }

    function test_CancelFastRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount);

        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        vm.prank(user1);
        minter.cancelFastRedeemOrder(orderId);
    }

    // Standard Redeem Tests
    function test_CreateStandardRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.expectEmit();
        emit StandardRedeemOrderCreated(0, user1, redeemAmount);
        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore);
        assertEq(collateralToken.balanceOf(address(minter)), mintAmount);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount);
        assertEq(minter.currentPendingStandardRedeemValue(), redeemAmount);
        assertEq(minter.standardRedeemOrderCount(), 1);

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(order.amount, redeemAmount);
        assertEq(order.owner, user1);
        assertEq(order.feePpm, 0);
        assertEq(order.dueTime, block.timestamp + minter.standardRedeemDelay());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_CreateStandardRedeemOrder_ZeroLimit_RevertLimitExceeded() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, redeemAmount, 0));
        vm.prank(user1);
        minter.createStandardRedeemOrder(redeemAmount);
    }

    function test_CreateStandardRedeemOrder_RevertInsufficientFunds() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.startPrank(user1);
        yzusd.burn(yzusd.balanceOf(user1));
        vm.expectRevert();
        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();
    }

    function test_FillStandardRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount);

        vm.warp(block.timestamp + minter.standardRedeemDelay());

        vm.expectEmit();
        emit StandardRedeemOrderFilled(user2, orderId, user1, redeemAmount, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount);

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillStandardRedeemOrder_WithFee() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;
        uint256 feePpm = 10_000; // 1%
        uint256 expectedFee = (redeemAmount * feePpm) / 1_000_000;
        uint256 collateralBalanceBefore = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(redeemManager);
        minter.setStandardRedeemFeePpm(feePpm);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount);

        vm.warp(block.timestamp + minter.standardRedeemDelay());

        vm.expectEmit();
        emit StandardRedeemOrderFilled(user2, orderId, user1, redeemAmount, expectedFee);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);

        assertEq(collateralToken.balanceOf(user1), collateralBalanceBefore + redeemAmount - expectedFee);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillStandardRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        collateralToken.mint(address(minter), mintAmount);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount);

        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);
    }

    function test_FillStandardRedeemOrder_RevertLiquidityBufferExceeded() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount);

        vm.expectRevert(abi.encodeWithSelector(LiquidityBufferExceeded.selector, redeemAmount, 0));
        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount);
    }
}
