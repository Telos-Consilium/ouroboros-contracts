// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

import {YuzuUSDMinter} from "../src/YuzuUSDMinter.sol";
import {YuzuUSD} from "../src/YuzuUSD.sol";
import {Order, OrderStatus} from "../src/interfaces/IYuzuUSDMinter.sol";
import {IYuzuUSDMinterDefinitions} from "../src/interfaces/IYuzuUSDMinterDefinitions.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract YuzuUSDMinterTest is IYuzuUSDMinterDefinitions, Test {
    YuzuUSDMinter public minter;
    YuzuUSD public yzusd;
    MockERC20 public collateralToken;

    address public admin;
    address public treasury;
    address public redeemFeeRecipient;
    address public user1;
    address public user2;
    address public filler;
    address public nonAdmin;

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
        filler = makeAddr("filler");
        nonAdmin = makeAddr("nonAdmin");

        // Deploy contracts
        vm.startPrank(admin);

        // Deploy YuzuUSD implementation and proxy
        yzusd = new YuzuUSD("Yuzu USD", "yzUSD", admin);

        collateralToken = new MockERC20("USDC", "USDC");

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

        // Set the minter contract as the minter for YuzuUSD
        yzusd.setMinter(address(minter));

        // Grant filler role
        minter.grantRole(ORDER_FILLER_ROLE, filler);
        vm.stopPrank();

        // Mint some collateral tokens to users for testing
        collateralToken.mint(user1, 10000e18);
        collateralToken.mint(user2, 10000e18);
        collateralToken.mint(filler, 10000e18);

        // Mint some collateral tokens to the minter for liquidity buffer
        collateralToken.mint(address(minter), 10000e18);
    }

    // Constructor Tests
    function test_Constructor() public view {
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
        assertEq(minter.standardFillWindow(), 7 days);
        assertTrue(minter.hasRole(ADMIN_ROLE, admin));
    }

    function test_Constructor_RevertInvalidZeroAddress() public {
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

    // Admin Function Tests
    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit();
        emit TreasuryUpdated(treasury, newTreasury);

        vm.prank(admin);
        minter.setTreasury(newTreasury);

        assertEq(minter.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertNonAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setTreasury(makeAddr("newTreasury"));
    }

    function test_SetRedeemFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit RedeemFeeRecipientUpdated(redeemFeeRecipient, newRecipient);

        vm.prank(admin);
        minter.setRedeemFeeRecipient(newRecipient);

        assertEq(minter.redeemFeeRecipient(), newRecipient);
    }

    function test_SetMaxMintPerBlock() public {
        uint256 newMaxMint = 2000e18;

        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit MaxMintPerBlockUpdated(MAX_MINT_PER_BLOCK, newMaxMint);

        vm.prank(admin);
        minter.setMaxMintPerBlock(newMaxMint);

        assertEq(minter.maxMintPerBlock(), newMaxMint);
    }

    function test_SetMaxRedeemPerBlock() public {
        uint256 newMaxRedeem = 1000e18;

        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit MaxRedeemPerBlockUpdated(MAX_REDEEM_PER_BLOCK, newMaxRedeem);

        vm.prank(admin);
        minter.setMaxRedeemPerBlock(newMaxRedeem);

        assertEq(minter.maxRedeemPerBlock(), newMaxRedeem);
    }

    function test_SetInstantRedeemFeePpm() public {
        uint256 newFee = 50; // 0.5%

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit InstantRedeemFeePpmUpdated(0, newFee);

        vm.prank(admin);
        minter.setInstantRedeemFeePpm(newFee);

        assertEq(minter.instantRedeemFeePpm(), newFee);
    }

    function test_SetFastRedeemFeePpm() public {
        uint256 newFee = 25; // 0.25%

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit FastRedeemFeePpmUpdated(0, newFee);

        vm.prank(admin);
        minter.setFastRedeemFeePpm(newFee);

        assertEq(minter.fastRedeemFeePpm(), newFee);
    }

    function test_SetStandardRedeemFeePpm() public {
        uint256 newFee = 10; // 0.1%

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit StandardRedeemFeePpmUpdated(0, newFee);

        vm.prank(admin);
        minter.setStandardRedeemFeePpm(newFee);

        assertEq(minter.standardRedeemFeePpm(), newFee);
    }

    function test_SetFastFillWindow() public {
        uint256 newWindow = 2 days;

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit FastFillWindowUpdated(1 days, newWindow);

        vm.prank(admin);
        minter.setFastFillWindow(newWindow);

        assertEq(minter.fastFillWindow(), newWindow);
    }

    function test_SetStandardFillWindow() public {
        uint256 newWindow = 14 days;

        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);

        vm.expectEmit();
        emit StandardFillWindowUpdated(7 days, newWindow);

        vm.prank(admin);
        minter.setStandardFillWindow(newWindow);

        assertEq(minter.standardFillWindow(), newWindow);
    }

    function test_WithdrawCollateral() public {
        uint256 amount = 10e18;
        address to = makeAddr("recipient");

        vm.expectEmit();
        emit CollateralWithdrawn(to, amount);

        vm.prank(admin);
        minter.withdrawCollateral(to, amount);

        assertEq(collateralToken.balanceOf(to), amount);
    }

    // Mint Tests
    function test_Mint() public {
        uint256 amount = 100e18;

        vm.startPrank(user1);
        collateralToken.approve(address(minter), amount);

        vm.expectEmit();
        emit Minted(user1, user1, amount);

        minter.mint(user1, amount);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1), amount);
        assertEq(collateralToken.balanceOf(treasury), amount);
        assertEq(minter.mintedPerBlock(block.number), amount);
    }

    function test_Mint_RevertInvalidZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidZeroAmount.selector));
        vm.prank(user1);
        minter.mint(user1, 0);
    }

    function test_Mint_RevertMaxMintPerBlockExceeded() public {
        uint256 amount = MAX_MINT_PER_BLOCK + 1;

        vm.startPrank(user1);
        collateralToken.approve(address(minter), amount);

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, amount, MAX_MINT_PER_BLOCK));
        minter.mint(user1, amount);
        vm.stopPrank();
    }

    function test_Mint_RevertZeroMaxMintPerBlock() public {
        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setMaxMintPerBlock(0);

        vm.startPrank(user1);
        collateralToken.approve(address(minter), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, 1000e18, 0));
        minter.mint(user1, 1000e18);
        vm.stopPrank();
    }

    // Instant Redeem Tests
    function test_InstantRedeem() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Then redeem
        yzusd.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount, 0);

        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);

        minter.instantRedeem(user1, redeemAmount);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1), mintAmount - redeemAmount);
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + redeemAmount);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount);
    }

    function test_InstantRedeem_WithFee() public {
        uint256 mintAmount = 1000e17;
        uint256 redeemAmount = 500e17;
        uint256 feePpm = 1e4; // 1%
        uint256 expectedFee = 5e17;

        // Set fee
        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setInstantRedeemFeePpm(feePpm);

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Then redeem
        yzusd.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount, expectedFee);

        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount);

        minter.instantRedeem(user1, redeemAmount);
        vm.stopPrank();

        uint256 expectedAmount = redeemAmount - expectedFee;

        assertEq(yzusd.balanceOf(user1), mintAmount - redeemAmount);
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + expectedAmount);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);
    }

    function test_InstantRedeem_RevertZeroMaxRedeemPerBlock() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Set max redeem per block to 0
        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setMaxRedeemPerBlock(0);

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Then redeem
        yzusd.approve(address(minter), redeemAmount);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, redeemAmount, 0));
        minter.instantRedeem(user1, redeemAmount);
        vm.stopPrank();
    }

    // Fast Redeem Tests
    function test_CreateFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Create fast redeem order
        yzusd.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit FastRedeemOrderCreated(0, user1, redeemAmount);

        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Check order was created
        Order memory order = minter.getFastRedeemOrder(0);
        assertEq(order.amount, redeemAmount);
        assertEq(order.owner, user1);
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
        assertEq(minter.fastRedeemOrderCount(), 1);
        assertEq(minter.currentPendingFastRedeemValue(), redeemAmount);
        assertEq(yzusd.balanceOf(address(minter)), redeemAmount);
    }

    function test_FastRedeem_ZeroMaxRedeemPerBlock() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Set max redeem per block to 0
        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setMaxRedeemPerBlock(0);

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Create fast redeem order
        yzusd.approve(address(minter), redeemAmount);
        vm.expectEmit();
        emit FastRedeemOrderCreated(0, user1, redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Check order was created
        Order memory order = minter.getFastRedeemOrder(0);
        assertEq(order.amount, redeemAmount);
        assertEq(order.owner, user1);
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
        assertEq(minter.fastRedeemOrderCount(), 1);
        assertEq(minter.currentPendingFastRedeemValue(), redeemAmount);
        assertEq(yzusd.balanceOf(address(minter)), redeemAmount);
    }

    function test_FillFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Setup: mint and create order
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Fill the order
        vm.startPrank(filler);
        collateralToken.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit FastRedeemOrderFilled(0, user1, filler, redeemFeeRecipient, redeemAmount, 0);

        minter.fillFastRedeemOrder(0, redeemFeeRecipient);
        vm.stopPrank();

        // Check order was filled
        Order memory order = minter.getFastRedeemOrder(0);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + redeemAmount);
        assertEq(minter.currentPendingFastRedeemValue(), 0);
    }

    function test_FillFastRedeemOrder_WithFee() public {
        uint256 mintAmount = 1000e17;
        uint256 redeemAmount = 500e17;
        uint256 feePpm = 1e4; // 1%
        uint256 expectedFee = 5e17;

        // Set fee
        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setFastRedeemFeePpm(feePpm);

        // Setup: mint and create order
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Fill the order
        vm.startPrank(filler);
        collateralToken.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit FastRedeemOrderFilled(0, user1, filler, redeemFeeRecipient, redeemAmount, expectedFee);

        minter.fillFastRedeemOrder(0, redeemFeeRecipient);
        vm.stopPrank();

        // Check order was filled
        Order memory order = minter.getFastRedeemOrder(0);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + redeemAmount - expectedFee);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);
        assertEq(minter.currentPendingFastRedeemValue(), 0);
    }

    function test_FillFastRedeemOrder_ZeroMaxRedeemPerBlock() public {
        vm.skip(true, "Not implemented.");
    }

    function test_FillFastRedeemOrder_PastDueTime() public {
        vm.skip(true, "Not implemented.");
    }

    function test_CancelFastRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        assertEq(minter.currentPendingFastRedeemValue(), redeemAmount);

        // Fast forward past the fill window
        vm.warp(block.timestamp + 7 days + 1);

        // Cancel the order
        vm.startPrank(user1);
        vm.expectEmit();
        emit IYuzuUSDMinterDefinitions.FastRedeemOrderCancelled(0);

        minter.cancelFastRedeemOrder(0);
        vm.stopPrank();

        // Check order was cancelled
        Order memory order = minter.getFastRedeemOrder(0);
        assertEq(uint256(order.status), uint256(OrderStatus.Cancelled));
        assertEq(minter.currentPendingFastRedeemValue(), 0);
    }

    function test_CancelFastRedeemOrder_RevertNotOwner() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Try to cancel as a different user
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector));
        vm.prank(user2);
        minter.cancelFastRedeemOrder(0);
    }

    function test_CancelFastRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createFastRedeemOrder(redeemAmount);

        // Try to cancel before due time
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, 0));
        minter.cancelFastRedeemOrder(0);
        vm.stopPrank();
    }

    // Standard Redeem Tests
    function test_CreateStandardRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Create standard redeem order
        yzusd.approve(address(minter), redeemAmount);

        vm.expectEmit();
        emit StandardRedeemOrderCreated(0, user1, redeemAmount);

        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Check order was created
        Order memory order = minter.getStandardRedeemOrder(0);
        assertEq(order.amount, redeemAmount);
        assertEq(order.owner, user1);
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
        assertEq(minter.standardRedeemOrderCount(), 1);
        assertEq(minter.currentPendingStandardRedeemValue(), redeemAmount);
    }

    function test_StandardRedeem_RevertZeroMaxRedeemPerBlock() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Set max redeem per block to 0
        vm.prank(admin);
        minter.grantRole(LIMIT_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setMaxRedeemPerBlock(0);

        // First mint some tokens
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);

        // Then redeem
        yzusd.approve(address(minter), redeemAmount);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, redeemAmount, 0));
        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();
    }

    function test_FillStandardRedeemOrder() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Setup: mint and create order
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Fast forward past the fill window
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectEmit();
        emit StandardRedeemOrderFilled(0, user1, redeemAmount, 0);

        minter.fillStandardRedeemOrder(0);

        // Check order was filled
        Order memory order = minter.getStandardRedeemOrder(0);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + redeemAmount);
        assertEq(minter.currentPendingStandardRedeemValue(), 0);
    }

    function test_FillStandardRedeemOrder_WithFee() public {
        uint256 mintAmount = 1000e17;
        uint256 redeemAmount = 500e17;
        uint256 feePpm = 1e4; // 1%
        uint256 expectedFee = 5e17;

        // Set fee
        vm.prank(admin);
        minter.grantRole(REDEEM_MANAGER_ROLE, admin);
        vm.prank(admin);
        minter.setStandardRedeemFeePpm(feePpm);

        // Setup: mint and create order
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Fast forward past the fill window
        vm.warp(block.timestamp + 7 days + 1);

        vm.expectEmit();
        emit StandardRedeemOrderFilled(0, user1, redeemAmount, expectedFee);

        minter.fillStandardRedeemOrder(0);

        // Check order was filled
        Order memory order = minter.getStandardRedeemOrder(0);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
        assertEq(collateralToken.balanceOf(user1), 10000e18 - mintAmount + redeemAmount - expectedFee);
        assertEq(collateralToken.balanceOf(redeemFeeRecipient), expectedFee);
        assertEq(minter.currentPendingStandardRedeemValue(), 0);
    }

    function test_FillStandardRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // Setup: mint and create order
        vm.startPrank(user1);
        collateralToken.approve(address(minter), mintAmount);
        minter.mint(user1, mintAmount);
        yzusd.approve(address(minter), redeemAmount);
        minter.createStandardRedeemOrder(redeemAmount);
        vm.stopPrank();

        // Try to fill before due time
        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, 0));
        minter.fillStandardRedeemOrder(0);
    }

    function test_FillStandardRedeemOrder_ZeroMaxRedeemPerBlock() public {
        vm.skip(true, "Not implemented.");
    }

    // Emergency Function Tests
    function test_RescueTokens() public {
        MockERC20 otherToken = new MockERC20("OTHER", "OTHER");
        uint256 amount = 100e18;

        otherToken.mint(address(minter), amount);

        vm.prank(admin);
        minter.rescueTokens(address(otherToken), treasury, amount);

        assertEq(otherToken.balanceOf(treasury), amount);
        assertEq(otherToken.balanceOf(address(minter)), 0);
    }

    function test_RescueTokens_RevertCollateralToken() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(collateralToken)));
        vm.prank(admin);
        minter.rescueTokens(address(collateralToken), treasury, 100e18);
    }

    function test_RescueTokens_RevertYuzuUSD() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(yzusd)));
        vm.prank(admin);
        minter.rescueTokens(address(yzusd), treasury, 100e18);
    }

    // Fuzz Tests
    function testFuzz_Mint(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MAX_MINT_PER_BLOCK);

        collateralToken.mint(user1, amount);

        vm.startPrank(user1);
        collateralToken.approve(address(minter), amount);
        minter.mint(user1, amount);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1), amount);
        assertEq(collateralToken.balanceOf(treasury), amount);
    }

    function testFuzz_InstantRedeem(uint256 amount) public {
        vm.assume(amount > 0 && amount <= MAX_REDEEM_PER_BLOCK);

        // Setup: mint tokens first
        collateralToken.mint(user1, amount);
        vm.startPrank(user1);
        collateralToken.approve(address(minter), amount);
        minter.mint(user1, amount);

        // Redeem
        yzusd.approve(address(minter), amount);
        minter.instantRedeem(user1, amount);
        vm.stopPrank();

        assertEq(yzusd.balanceOf(user1), 0);
    }

    function test_SetMaxMintPerBlock_RevertNonAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxMintPerBlock(2000e18);
    }

    function test_SetMaxRedeemPerBlock_RevertNonAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxRedeemPerBlock(1000e18);
    }

    function test_Mint_MultipleMintsInSameBlock() public {
        uint256 mintAmount1 = 400e18;
        uint256 mintAmount2 = 500e18;

        // First mint should succeed
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount1);
        vm.prank(user1);
        minter.mint(user2, mintAmount1);

        // Second mint should succeed (total: 900e18)
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount2);
        vm.prank(user1);
        minter.mint(user2, mintAmount2);

        assertEq(minter.mintedPerBlock(block.number), mintAmount1 + mintAmount2);

        // Third mint should fail (would exceed 1000e18)
        uint256 mintAmount3 = 200e18;
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount3);

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, mintAmount3, MAX_MINT_PER_BLOCK));
        vm.prank(user1);
        minter.mint(user2, mintAmount3);
    }

    function test_Mint_DifferentBlocks() public {
        uint256 mintAmount = MAX_MINT_PER_BLOCK;

        // First block - max mint
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user2, mintAmount);

        // Move to next block
        vm.roll(block.number + 1);

        // Should be able to mint max amount again in new block
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user2, mintAmount);

        assertEq(minter.mintedPerBlock(block.number - 1), mintAmount);
        assertEq(minter.mintedPerBlock(block.number), mintAmount);
    }
}
