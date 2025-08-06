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

contract USDCMock is ERC20Mock {
    constructor() ERC20Mock() {}

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}

contract YuzuUSDMinterTest is IYuzuUSDMinterDefinitions, Test {
    YuzuUSDMinter public minter;
    YuzuUSD public yzusd;
    USDCMock public collateralToken;

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

        collateralToken = new USDCMock();

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

        // Mint some collateral tokens to users (6 decimals)
        collateralToken.mint(user1, 10_000e6);
        collateralToken.mint(user2, 10_000e6);
        collateralToken.mint(orderFiller, 10_000e6);

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

    function test_SetTreasury_RevertOnlyAdmin() public {
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

    function test_SetRedeemFeeRecipient_RevertOnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setRedeemFeeRecipient(makeAddr("newRecipient"));
    }

    function test_SetMaxMintPerBlock() public {
        uint256 newMaxMintPerBlock = 2000e18;

        vm.expectEmit();
        emit MaxMintPerBlockUpdated(MAX_MINT_PER_BLOCK, newMaxMintPerBlock);
        vm.prank(limitManager);
        minter.setMaxMintPerBlock(newMaxMintPerBlock);

        assertEq(minter.maxMintPerBlock(), newMaxMintPerBlock);
    }

    function test_SetMaxMintPerBlock_RevertOnlyLimitManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxMintPerBlock(2000e18);
    }

    function test_SetMaxRedeemPerBlock() public {
        uint256 newMaxRedeemPerBlock = 1000e18;

        vm.expectEmit();
        emit MaxRedeemPerBlockUpdated(MAX_REDEEM_PER_BLOCK, newMaxRedeemPerBlock);
        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(newMaxRedeemPerBlock);

        assertEq(minter.maxRedeemPerBlock(), newMaxRedeemPerBlock);
    }

    function test_SetMaxRedeemPerBlock_RevertOnlyLimitManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxRedeemPerBlock(1000e18);
    }

    function test_SetInstantRedeemFeePpm() public {
        uint256 newInstantRedeemFeePpm = 5_000;

        vm.expectEmit();
        emit InstantRedeemFeePpmUpdated(0, newInstantRedeemFeePpm);
        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(newInstantRedeemFeePpm);

        assertEq(minter.instantRedeemFeePpm(), newInstantRedeemFeePpm);
    }

    function test_SetInstantRedeemFeePpm_RevertOnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setInstantRedeemFeePpm(5_000);
    }

    function test_SetFastRedeemFeePpm() public {
        uint256 newFastRedeemFeePpm = 2_500;

        vm.expectEmit();
        emit FastRedeemFeePpmUpdated(0, newFastRedeemFeePpm);
        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(newFastRedeemFeePpm);

        assertEq(minter.fastRedeemFeePpm(), newFastRedeemFeePpm);
    }

    function test_SetFastRedeemFeePpm_RevertOnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setFastRedeemFeePpm(2_500);
    }

    function test_SetStandardRedeemFeePpm() public {
        uint256 newStandardRedeemFeePpm = 1_000;

        vm.expectEmit();
        emit StandardRedeemFeePpmUpdated(0, newStandardRedeemFeePpm);
        vm.prank(redeemManager);
        minter.setStandardRedeemFeePpm(newStandardRedeemFeePpm);

        assertEq(minter.standardRedeemFeePpm(), newStandardRedeemFeePpm);
    }

    function test_SetStandardRedeemFeePpm_RevertOnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setStandardRedeemFeePpm(1_000);
    }

    function test_SetFastFillWindow() public {
        uint256 newFastFillWindow = 2 days;

        vm.expectEmit();
        emit FastFillWindowUpdated(1 days, newFastFillWindow);
        vm.prank(redeemManager);
        minter.setFastFillWindow(newFastFillWindow);

        assertEq(minter.fastFillWindow(), newFastFillWindow);
    }

    function test_SetFastFillWindow_RevertOnlyRedeemManager() public {
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

    function test_SetStandardRedeemDelay_RevertOnlyRedeemManager() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setStandardRedeemDelay(14 days);
    }

    function test_WithdrawCollateral() public {
        uint256 collateralAmount = 100e6;
        address recipient = makeAddr("recipient");

        collateralToken.mint(address(minter), collateralAmount);

        vm.expectEmit();
        emit CollateralWithdrawn(recipient, collateralAmount);
        vm.prank(admin);
        minter.withdrawCollateral(collateralAmount, recipient);

        assertEq(collateralToken.balanceOf(recipient), collateralAmount);
    }

    function test_RescueTokens() public {
        USDCMock otherToken = new USDCMock();
        uint256 tokenAmount = 100e6;
        otherToken.mint(address(minter), tokenAmount);
        uint256 userBalanceBefore = otherToken.balanceOf(user1);
        vm.prank(admin);
        minter.rescueTokens(address(otherToken), user1, tokenAmount);
        assertEq(otherToken.balanceOf(user1), userBalanceBefore + tokenAmount);
    }

    function test_RescueTokens_RevertOnlyOwner() public {
        USDCMock otherToken = new USDCMock();
        uint256 tokenAmount = 100e6;
        otherToken.mint(address(minter), tokenAmount);
        vm.expectRevert();
        vm.prank(user1);
        minter.rescueTokens(address(otherToken), user1, tokenAmount);
    }

    function test_RescueTokens_YzUSD() public {
        uint256 yzusdAmount = 100e18;
        vm.prank(address(minter));
        yzusd.mint(address(minter), yzusdAmount);
        uint256 userBalanceBefore = yzusd.balanceOf(user1);
        vm.prank(admin);
        minter.rescueTokens(address(yzusd), user1, yzusdAmount);
        assertEq(yzusd.balanceOf(user1), userBalanceBefore + yzusdAmount);
    }

    function test_RescueTokens_YzUSD_RevertInsufficientOutstandingBalance() public {
        uint256 yzusdAmount = 100e18;
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutstandingBalance.selector, yzusdAmount, 0));
        vm.prank(admin);
        minter.rescueTokens(address(yzusd), user1, yzusdAmount);
    }

    function test_RescueTokens_RevertUnderlyingToken() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidToken.selector, address(collateralToken)));
        vm.prank(admin);
        minter.rescueTokens(address(collateralToken), user1, 100e6);
    }

    // Mint
    function test_Mint() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 expectedDeposit_usdc = 100e6;

        vm.expectEmit();
        emit Minted(user1, user1, mintAmount_yzusd);
        vm.prank(user1);
        uint256 depositedCollateral_usdc = minter.mint(mintAmount_yzusd, user1);

        assertEq(depositedCollateral_usdc, expectedDeposit_usdc);
        assertEq(yzusd.balanceOf(user1), mintAmount_yzusd);
        assertEq(collateralToken.balanceOf(treasury), expectedDeposit_usdc);
        assertEq(minter.mintedPerBlock(block.number), mintAmount_yzusd);
    }

    function test_Mint_RevertInvalidZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidZeroAmount.selector));
        vm.prank(user1);
        minter.mint(0, user1);
    }

    function test_Mint_RevertLimitExceeded() public {
        uint256 mintAmount_yzusd = MAX_MINT_PER_BLOCK + 1;

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, mintAmount_yzusd, MAX_MINT_PER_BLOCK));
        vm.prank(user1);
        minter.mint(mintAmount_yzusd, user1);
    }

    function test_Mint_ZeroLimit_RevertLimitExceeded() public {
        uint256 mintAmount_yzusd = 100e18;

        vm.prank(limitManager);
        minter.setMaxMintPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxMintPerBlockExceeded.selector, mintAmount_yzusd, 0));
        vm.prank(user1);
        minter.mint(mintAmount_yzusd, user1);
    }

    // Instant Redeem
    function test_InstantRedeem() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;
        uint256 expectedCollateralWithdrawal_usdc = redeemAmount_yzusd / (10 ** 12);

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount_yzusd, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(user1);
        uint256 withdrawnCollateral_usdc = minter.instantRedeem(redeemAmount_yzusd, user1);

        assertEq(withdrawnCollateral_usdc, expectedCollateralWithdrawal_usdc);
        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralWithdrawal_usdc);
        assertEq(collateralToken.balanceOf(address(minter)), liquidityBuffer_usdc - expectedCollateralWithdrawal_usdc);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount_yzusd);
    }

    function test_InstantRedeem_WithFee() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;
        uint256 feePpm = 10_000;

        uint256 collateralAmountWithFee_usdc = redeemAmount_yzusd / (10 ** 12);
        uint256 expectedCollateralFee_usdc = Math.mulDiv(collateralAmountWithFee_usdc, feePpm, 1e6, Math.Rounding.Ceil);
        uint256 expectedCollateralWithdrawal_usdc = collateralAmountWithFee_usdc - expectedCollateralFee_usdc;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);
        uint256 feeRecipientCollateralBefore_usdc = collateralToken.balanceOf(redeemFeeRecipient);

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(feePpm);

        vm.expectEmit();
        emit InstantRedeem(user1, user1, redeemAmount_yzusd, expectedCollateralFee_usdc);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(user1);
        uint256 withdrawnCollateral_usdc = minter.instantRedeem(redeemAmount_yzusd, user1);

        assertEq(withdrawnCollateral_usdc, expectedCollateralWithdrawal_usdc);
        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralWithdrawal_usdc);
        assertEq(
            collateralToken.balanceOf(redeemFeeRecipient),
            feeRecipientCollateralBefore_usdc + expectedCollateralFee_usdc
        );
        assertEq(yzusd.balanceOf(user1), mintAmount_yzusd - redeemAmount_yzusd);
    }

    function test_InstantRedeem_RevertLimitExceeded() public {
        uint256 mintAmount_yzusd = MAX_REDEEM_PER_BLOCK + 1;

        collateralToken.mint(address(minter), mintAmount_yzusd);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectRevert(
            abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, mintAmount_yzusd, MAX_REDEEM_PER_BLOCK)
        );
        vm.prank(user1);
        minter.instantRedeem(mintAmount_yzusd, user1);
    }

    function test_InstantRedeem_ZeroLimit_RevertLimitExceeded() public {
        uint256 mintAmount_yzusd = MAX_REDEEM_PER_BLOCK + 1;

        collateralToken.mint(address(minter), mintAmount_yzusd);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, mintAmount_yzusd, 0));
        vm.prank(user1);
        minter.instantRedeem(mintAmount_yzusd, user1);
    }

    function test_InstantRedeem_RevertInsufficientFunds() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;

        collateralToken.mint(address(minter), mintAmount_yzusd);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.startPrank(user1);
        yzusd.burn(yzusd.balanceOf(user1));
        vm.expectRevert();
        minter.instantRedeem(redeemAmount_yzusd, user1);
        vm.stopPrank();
    }

    function test_InstantRedeem_RevertLiquidityBufferExceeded() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 expectedCollateralWithdrawal_usdc = redeemAmount_yzusd / (10 ** 12);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectRevert(abi.encodeWithSelector(LiquidityBufferExceeded.selector, expectedCollateralWithdrawal_usdc, 0));
        vm.prank(user1);
        minter.instantRedeem(redeemAmount_yzusd, user1);
    }

    // Fast Redeem
    function test_CreateFastRedeemOrder() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectEmit();
        emit FastRedeemOrderCreated(0, user1, redeemAmount_yzusd);
        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc);
        assertEq(collateralToken.balanceOf(address(minter)), 0);
        assertEq(minter.redeemedPerBlock(block.number), 0);
        assertEq(minter.currentPendingFastRedeemValue(), redeemAmount_yzusd);
        assertEq(minter.fastRedeemOrderCount(), 1);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(order.amount, redeemAmount_yzusd);
        assertEq(order.owner, user1);
        assertEq(order.feePpm, 0);
        assertEq(order.dueTime, block.timestamp + minter.fastFillWindow());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_FillFastRedeemOrder() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 expectedCollateralWithdrawal_usdc = 50e6;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        vm.expectEmit();
        emit FastRedeemOrderFilled(orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount_yzusd, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralWithdrawal_usdc);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillFastRedeemOrder_WithFee() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 feePpm = 10_000;

        uint256 collateralAmountWithFee_usdc = redeemAmount_yzusd / (10 ** 12);
        uint256 expectedCollateralFee_usdc = Math.mulDiv(collateralAmountWithFee_usdc, feePpm, 1e6, Math.Rounding.Ceil);
        uint256 expectedCollateralWithdrawal_usdc = collateralAmountWithFee_usdc - expectedCollateralFee_usdc;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);
        uint256 feeRecipientCollateralBefore_usdc = collateralToken.balanceOf(redeemFeeRecipient);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(feePpm);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        vm.expectEmit();
        emit FastRedeemOrderFilled(
            orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount_yzusd, expectedCollateralFee_usdc
        );
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralWithdrawal_usdc);
        assertEq(
            collateralToken.balanceOf(redeemFeeRecipient),
            feeRecipientCollateralBefore_usdc + expectedCollateralFee_usdc
        );

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillFastRedeemOrder_PastDueTime() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 expectedCollateralWithdrawal_usdc = 50e6;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        vm.warp(block.timestamp + minter.fastFillWindow());

        vm.expectEmit();
        emit FastRedeemOrderFilled(orderId, user1, orderFiller, redeemFeeRecipient, redeemAmount_yzusd, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, redeemFeeRecipient);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralWithdrawal_usdc);

        Order memory order = minter.getFastRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_CancelFastRedeemOrder() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

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
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        vm.warp(block.timestamp + minter.fastFillWindow());

        vm.expectRevert();
        vm.prank(user2);
        minter.cancelFastRedeemOrder(orderId);
    }

    function test_CancelFastRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        vm.prank(user1);
        minter.cancelFastRedeemOrder(orderId);
    }

    // Standard Redeem
    function test_CreateStandardRedeemOrder() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectEmit();
        emit StandardRedeemOrderCreated(0, user1, redeemAmount_yzusd);
        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount_yzusd);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc);
        assertEq(collateralToken.balanceOf(address(minter)), liquidityBuffer_usdc);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount_yzusd);
        assertEq(minter.currentPendingStandardRedeemValue(), redeemAmount_yzusd);
        assertEq(minter.standardRedeemOrderCount(), 1);

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(order.amount, redeemAmount_yzusd);
        assertEq(order.owner, user1);
        assertEq(order.feePpm, 0);
        assertEq(order.dueTime, block.timestamp + minter.standardRedeemDelay());
        assertEq(uint256(order.status), uint256(OrderStatus.Pending));
    }

    function test_CreateStandardRedeemOrder_ZeroLimit_RevertLimitExceeded() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.expectRevert(abi.encodeWithSelector(MaxRedeemPerBlockExceeded.selector, redeemAmount_yzusd, 0));
        vm.prank(user1);
        minter.createStandardRedeemOrder(redeemAmount_yzusd);
    }

    function test_CreateStandardRedeemOrder_RevertInsufficientFunds() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(limitManager);
        minter.setMaxRedeemPerBlock(0);

        vm.startPrank(user1);
        yzusd.burn(yzusd.balanceOf(user1));
        vm.expectRevert();
        minter.createStandardRedeemOrder(redeemAmount_yzusd);
        vm.stopPrank();
    }

    function test_FillStandardRedeemOrder() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;
        uint256 expectedCollateralAmount_usdc = 50e6;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount_yzusd);

        vm.warp(block.timestamp + minter.standardRedeemDelay());

        vm.expectEmit();
        emit StandardRedeemOrderFilled(user2, orderId, user1, redeemAmount_yzusd, 0);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralAmount_usdc);

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillStandardRedeemOrder_WithFee() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;
        uint256 feePpm = 10_000;

        uint256 collateralAmountWithFee_usdc = redeemAmount_yzusd / (10 ** 12);
        uint256 expectedCollateralFee_usdc = Math.mulDiv(collateralAmountWithFee_usdc, feePpm, 1e6, Math.Rounding.Ceil);
        uint256 expectedCollateralAmount_usdc = collateralAmountWithFee_usdc - expectedCollateralFee_usdc;

        uint256 userCollateralBefore_usdc = collateralToken.balanceOf(user1);
        uint256 feeRecipientCollateralBefore_usdc = collateralToken.balanceOf(redeemFeeRecipient);

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(redeemManager);
        minter.setStandardRedeemFeePpm(feePpm);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount_yzusd);

        vm.warp(block.timestamp + minter.standardRedeemDelay());

        vm.expectEmit();
        emit StandardRedeemOrderFilled(user2, orderId, user1, redeemAmount_yzusd, expectedCollateralFee_usdc);
        vm.expectEmit();
        emit Redeemed(user1, user1, redeemAmount_yzusd);
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);

        assertEq(collateralToken.balanceOf(user1), userCollateralBefore_usdc + expectedCollateralAmount_usdc);
        assertEq(
            collateralToken.balanceOf(redeemFeeRecipient),
            feeRecipientCollateralBefore_usdc + expectedCollateralFee_usdc
        );

        Order memory order = minter.getStandardRedeemOrder(orderId);
        assertEq(uint256(order.status), uint256(OrderStatus.Filled));
    }

    function test_FillStandardRedeemOrder_RevertOrderNotDue() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 liquidityBuffer_usdc = 100e6;

        collateralToken.mint(address(minter), liquidityBuffer_usdc);
        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.prank(user1);
        uint256 orderId = minter.createStandardRedeemOrder(redeemAmount_yzusd);

        vm.expectRevert(abi.encodeWithSelector(OrderNotDue.selector, orderId));
        vm.prank(user2);
        minter.fillStandardRedeemOrder(orderId);
    }

    function test_FillStandardRedeemOrder_RevertLiquidityBufferExceeded() public {
        uint256 mintAmount_yzusd = 100e18;
        uint256 redeemAmount_yzusd = 50e18;
        uint256 expectedCollateralAmount_usdc = redeemAmount_yzusd / (10 ** 12);

        vm.prank(address(minter));
        yzusd.mint(user1, mintAmount_yzusd);

        vm.expectRevert(abi.encodeWithSelector(LiquidityBufferExceeded.selector, expectedCollateralAmount_usdc, 0));
        vm.prank(user1);
        minter.createStandardRedeemOrder(redeemAmount_yzusd);
    }

    // Fee Collection
    function test_ContractFeeCollection() public {
        uint256 collateralFeeAmount_usdc = 1e6;

        address customRecipient = makeAddr("customRecipient");

        vm.prank(redeemManager);
        minter.setRedeemFeeRecipient(customRecipient);

        collateralToken.mint(address(minter), collateralFeeAmount_usdc);

        uint256 recipientCollateralBefore_usdc = collateralToken.balanceOf(customRecipient);

        uint256 redeemAmount_yzusd = 10e18;
        uint256 feePpm = 100_000;

        vm.prank(address(minter));
        yzusd.mint(user1, redeemAmount_yzusd);

        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(feePpm);

        collateralToken.mint(address(minter), 10e6);

        vm.prank(user1);
        minter.instantRedeem(redeemAmount_yzusd, user1);

        assertEq(collateralToken.balanceOf(customRecipient), recipientCollateralBefore_usdc + collateralFeeAmount_usdc);
    }

    function test_ContractFeeCollection_SameRecipient() public {
        uint256 redeemAmount_yzusd = 10e18;
        uint256 feePpm = 100_000;

        vm.prank(redeemManager);
        minter.setRedeemFeeRecipient(address(minter));

        vm.prank(address(minter));
        yzusd.mint(user1, redeemAmount_yzusd);

        vm.prank(redeemManager);
        minter.setInstantRedeemFeePpm(feePpm);

        collateralToken.mint(address(minter), 10e6);

        uint256 minterCollateralBefore_usdc = collateralToken.balanceOf(address(minter));

        vm.prank(user1);
        minter.instantRedeem(redeemAmount_yzusd, user1);

        assertEq(collateralToken.balanceOf(address(minter)), minterCollateralBefore_usdc - 9e6);
    }

    function test_FillerFeeCollection() public {
        uint256 redeemAmount_yzusd = 10e18;
        uint256 feePpm = 100_000;

        uint256 collateralAmountWithFee_usdc = redeemAmount_yzusd / (10 ** 12);
        uint256 collateralFeeAmount_usdc = Math.mulDiv(collateralAmountWithFee_usdc, feePpm, 1e6, Math.Rounding.Ceil);
        uint256 collateralAmount_usdc = collateralAmountWithFee_usdc - collateralFeeAmount_usdc;

        address customFeeRecipient = makeAddr("customFeeRecipient");

        vm.prank(address(minter));
        yzusd.mint(user1, redeemAmount_yzusd);

        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(feePpm);

        collateralToken.mint(orderFiller, collateralAmount_usdc + collateralFeeAmount_usdc);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        uint256 fillerCollateralBefore_usdc = collateralToken.balanceOf(orderFiller);
        uint256 recipientCollateralBefore_usdc = collateralToken.balanceOf(customFeeRecipient);

        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, customFeeRecipient);

        assertEq(
            collateralToken.balanceOf(orderFiller),
            fillerCollateralBefore_usdc - collateralAmount_usdc - collateralFeeAmount_usdc
        );
        assertEq(
            collateralToken.balanceOf(customFeeRecipient), recipientCollateralBefore_usdc + collateralFeeAmount_usdc
        );
    }

    function test_FillerFeeCollection_SameRecipient() public {
        uint256 redeemAmount_yzusd = 10e18;
        uint256 feePpm = 100_000;

        uint256 collateralAmountWithFee_usdc = redeemAmount_yzusd / (10 ** 12);
        uint256 collateralFeeAmount_usdc = Math.mulDiv(collateralAmountWithFee_usdc, feePpm, 1e6, Math.Rounding.Ceil);
        uint256 collateralAmount_usdc = collateralAmountWithFee_usdc - collateralFeeAmount_usdc;

        vm.prank(address(minter));
        yzusd.mint(user1, redeemAmount_yzusd);

        vm.prank(redeemManager);
        minter.setFastRedeemFeePpm(feePpm);

        collateralToken.mint(orderFiller, collateralAmount_usdc);

        vm.prank(user1);
        uint256 orderId = minter.createFastRedeemOrder(redeemAmount_yzusd);

        uint256 fillerCollateralBefore_usdc = collateralToken.balanceOf(orderFiller);

        vm.prank(orderFiller);
        minter.fillFastRedeemOrder(orderId, orderFiller);

        assertEq(collateralToken.balanceOf(orderFiller), fillerCollateralBefore_usdc - collateralAmount_usdc);
    }
}
