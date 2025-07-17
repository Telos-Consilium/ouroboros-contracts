// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {YuzuUSDMinter} from "../src/YuzuUSDMinter.sol";
import {YuzuUSD} from "../src/YuzuUSD.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract YuzuUSDMinterTest is Test {
    YuzuUSDMinter public minter;
    YuzuUSD public yzusd;
    MockERC20 public collateralToken;

    address public admin;
    address public treasury;
    address public user1;
    address public user2;
    address public nonAdmin;

    uint256 public constant MAX_MINT_PER_BLOCK = 1000e18;
    uint256 public constant MAX_REDEEM_PER_BLOCK = 500e18;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Events from IYuzuUSDMinterDefinitions
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event MaxMintPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event MaxRedeemPerBlockUpdated(uint256 oldMax, uint256 newMax);

    // Custom errors
    error InvalidZeroAddress();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        nonAdmin = makeAddr("nonAdmin");

        // Deploy contracts
        vm.startPrank(admin);
        yzusd = new YuzuUSD(admin);
        collateralToken = new MockERC20("USDC", "USDC");

        minter = new YuzuUSDMinter(
            address(yzusd),
            address(collateralToken),
            treasury,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );

        // Set the minter contract as the minter for YuzuUSD
        yzusd.setMinter(address(minter));
        vm.stopPrank();

        // Mint some collateral tokens to users for testing
        collateralToken.mint(user1, 10000e18);
        collateralToken.mint(user2, 10000e18);

        // Mint some collateral tokens for the liquidity buffer
        collateralToken.mint(address(minter), 10000e18);
    }

    function test_Constructor() public {
        assertEq(address(minter.yzusd()), address(yzusd));
        assertEq(minter.collateralToken(), address(collateralToken));
        assertEq(minter.treasury(), treasury);
        assertEq(minter.maxMintPerBlock(), MAX_MINT_PER_BLOCK);
        assertEq(minter.maxRedeemPerBlock(), MAX_REDEEM_PER_BLOCK);
        assertTrue(minter.hasRole(ADMIN_ROLE, admin));
        assertTrue(minter.hasRole(minter.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertInvalidZeroAddress() public {
        vm.expectRevert(InvalidZeroAddress.selector);
        new YuzuUSDMinter(
            address(0),
            address(collateralToken),
            treasury,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );

        vm.expectRevert(InvalidZeroAddress.selector);
        new YuzuUSDMinter(
            address(yzusd),
            address(0),
            treasury,
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );

        vm.expectRevert(InvalidZeroAddress.selector);
        new YuzuUSDMinter(
            address(yzusd),
            address(collateralToken),
            address(0),
            MAX_MINT_PER_BLOCK,
            MAX_REDEEM_PER_BLOCK
        );
    }

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);

        vm.prank(admin);
        minter.setTreasury(newTreasury);

        assertEq(minter.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertNonAdmin() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setTreasury(newTreasury);
    }

    function test_SetTreasury_RevertInvalidZeroAddress() public {
        vm.expectRevert(InvalidZeroAddress.selector);
        vm.prank(admin);
        minter.setTreasury(address(0));
    }

    function test_SetMaxMintPerBlock() public {
        uint256 newMaxMint = 2000e18;

        vm.expectEmit(false, false, false, true);
        emit MaxMintPerBlockUpdated(MAX_MINT_PER_BLOCK, newMaxMint);

        vm.prank(admin);
        minter.setMaxMintPerBlock(newMaxMint);

        assertEq(minter.maxMintPerBlock(), newMaxMint);
    }

    function test_SetMaxMintPerBlock_RevertNonAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxMintPerBlock(2000e18);
    }

    function test_SetMaxRedeemPerBlock() public {
        uint256 newMaxRedeem = 1000e18;

        vm.expectEmit(false, false, false, true);
        emit MaxRedeemPerBlockUpdated(MAX_REDEEM_PER_BLOCK, newMaxRedeem);

        vm.prank(admin);
        minter.setMaxRedeemPerBlock(newMaxRedeem);

        assertEq(minter.maxRedeemPerBlock(), newMaxRedeem);
    }

    function test_SetMaxRedeemPerBlock_RevertNonAdmin() public {
        vm.expectRevert();
        vm.prank(nonAdmin);
        minter.setMaxRedeemPerBlock(1000e18);
    }

    function test_Mint() public {
        uint256 mintAmount = 100e18;

        // Approve collateral transfer
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);

        uint256 treasuryBalanceBefore = collateralToken.balanceOf(treasury);
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user2);

        vm.prank(user1);
        minter.mint(user2, mintAmount);

        assertEq(
            collateralToken.balanceOf(treasury),
            treasuryBalanceBefore + mintAmount
        );
        assertEq(yzusd.balanceOf(user2), yzusdBalanceBefore + mintAmount);
        assertEq(minter.mintedPerBlock(block.number), mintAmount);
    }

    function test_Mint_RevertMaxMintPerBlockExceeded() public {
        uint256 mintAmount = MAX_MINT_PER_BLOCK + 1;

        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);

        vm.expectRevert(MaxMintPerBlockExceeded.selector);
        vm.prank(user1);
        minter.mint(user2, mintAmount);
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

        assertEq(
            minter.mintedPerBlock(block.number),
            mintAmount1 + mintAmount2
        );

        // Third mint should fail (would exceed 1000e18)
        uint256 mintAmount3 = 200e18;
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount3);

        vm.expectRevert(MaxMintPerBlockExceeded.selector);
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

    function test_Redeem() public {
        uint256 mintAmount = 100e18;
        uint256 redeemAmount = 50e18;

        // First mint some tokens
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user1, mintAmount);

        // Approve YuzuUSD for burning
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount);

        uint256 minterBalanceBefore = collateralToken.balanceOf(
            address(minter)
        );
        uint256 user2CollateralBefore = collateralToken.balanceOf(user2);
        uint256 yzusdBalanceBefore = yzusd.balanceOf(user1);

        vm.prank(user1);
        minter.redeem(user2, redeemAmount);

        assertEq(
            collateralToken.balanceOf(address(minter)),
            minterBalanceBefore - redeemAmount
        );
        assertEq(
            collateralToken.balanceOf(user2),
            user2CollateralBefore + redeemAmount
        );
        assertEq(yzusd.balanceOf(user1), yzusdBalanceBefore - redeemAmount);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount);
    }

    function test_Redeem_RevertMaxRedeemPerBlockExceeded() public {
        uint256 mintAmount = MAX_REDEEM_PER_BLOCK + 100e18;
        uint256 redeemAmount = MAX_REDEEM_PER_BLOCK + 1;

        // First mint enough tokens
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user1, mintAmount);

        // Approve YuzuUSD for burning
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount);

        vm.expectRevert(MaxRedeemPerBlockExceeded.selector);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount);
    }

    function test_Redeem_MultipleRedeemsInSameBlock() public {
        uint256 mintAmount = 1000e18;
        uint256 redeemAmount1 = 200e18;
        uint256 redeemAmount2 = 250e18;

        // First mint enough tokens
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user1, mintAmount);

        // First redeem should succeed
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount1);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount1);

        // Second redeem should succeed (total: 450e18)
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount2);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount2);

        assertEq(
            minter.redeemedPerBlock(block.number),
            redeemAmount1 + redeemAmount2
        );

        // Third redeem should fail (would exceed 500e18)
        uint256 redeemAmount3 = 100e18;
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount3);

        vm.expectRevert(MaxRedeemPerBlockExceeded.selector);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount3);
    }

    function test_Redeem_DifferentBlocks() public {
        uint256 mintAmount = MAX_REDEEM_PER_BLOCK * 2;
        uint256 redeemAmount = MAX_REDEEM_PER_BLOCK;

        // First mint enough tokens
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user1, mintAmount);

        // First block - max redeem
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount);

        // Move to next block
        vm.roll(block.number + 1);

        // Should be able to redeem max amount again in new block
        vm.prank(user1);
        yzusd.approve(address(minter), redeemAmount);
        vm.prank(user1);
        minter.redeem(user2, redeemAmount);

        assertEq(minter.redeemedPerBlock(block.number - 1), redeemAmount);
        assertEq(minter.redeemedPerBlock(block.number), redeemAmount);
    }

    function test_MintedPerBlock_Tracking() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 currentBlock = block.number;

        vm.prank(user1);
        collateralToken.approve(address(minter), amount1 + amount2);

        vm.prank(user1);
        minter.mint(user1, amount1);
        assertEq(minter.mintedPerBlock(currentBlock), amount1);

        vm.prank(user1);
        minter.mint(user1, amount2);
        assertEq(minter.mintedPerBlock(currentBlock), amount1 + amount2);

        // Different block should have zero initially
        assertEq(minter.mintedPerBlock(currentBlock + 1), 0);
    }

    function test_RedeemedPerBlock_Tracking() public {
        uint256 mintAmount = 1000e18;
        uint256 redeem1 = 100e18;
        uint256 redeem2 = 200e18;
        uint256 currentBlock = block.number;

        // Setup: mint tokens first
        vm.prank(user1);
        collateralToken.approve(address(minter), mintAmount);
        vm.prank(user1);
        minter.mint(user1, mintAmount);

        // Test redeem tracking
        vm.prank(user1);
        yzusd.approve(address(minter), redeem1 + redeem2);

        vm.prank(user1);
        minter.redeem(user1, redeem1);
        assertEq(minter.redeemedPerBlock(currentBlock), redeem1);

        vm.prank(user1);
        minter.redeem(user1, redeem2);
        assertEq(minter.redeemedPerBlock(currentBlock), redeem1 + redeem2);

        // Different block should have zero initially
        assertEq(minter.redeemedPerBlock(currentBlock + 1), 0);
    }
}
