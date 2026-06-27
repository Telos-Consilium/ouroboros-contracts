// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../src/YuzuUSDV3Facet.sol";
import {IYuzuSameBlockGuardDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuV3SameBlockGuardTest is Test, IYuzuSameBlockGuardDefinitions {
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    USDT0Mock asset;
    YuzuUSDV3 yzusd;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address user = makeAddr("user");
    address other = makeAddr("other");
    address exempt = makeAddr("exempt");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);
        asset.mint(other, 10_000_000e6);
        asset.mint(exempt, 10_000_000e6);

        address impl = address(new YuzuUSDV3(address(new YuzuUSDV3Facet())));
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            address(asset),
            "Token",
            "TKN",
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        address proxy = address(new ERC1967Proxy(impl, initData));
        yzusd = YuzuUSDV3(proxy);
        YuzuUSDV2(proxy).reinitialize();
        yzusd.reinitializeV3();

        vm.startPrank(admin);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
        vm.prank(other);
        asset.approve(proxy, type(uint256).max);
        vm.prank(exempt);
        asset.approve(proxy, type(uint256).max);
    }

    function test_SameBlock_Withdraw_Reverts() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, user));
        yzusd.withdraw(50e6, user, user);
    }

    function test_SameBlock_Redeem_Reverts() public {
        vm.prank(user);
        uint256 shares = yzusd.deposit(100e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, user));
        yzusd.redeem(shares / 2, user, user);
    }

    function test_NextBlock_Withdraw_Succeeds() public {
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.roll(block.number + 1);
        vm.prank(user);
        yzusd.withdraw(50e6, user, user);
    }

    function test_SameBlock_StampsReceiverNotCaller() public {
        // user mints to `other`; the guard stamps the receiver
        vm.prank(user);
        yzusd.deposit(100e6, other);

        assertEq(yzusd.lastMintBlock(other), block.number);
        assertEq(yzusd.lastMintBlock(user), 0);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SameBlockMintRedeem.selector, other));
        yzusd.withdraw(50e6, other, other);
    }

    function test_SameBlock_ExemptReceiver_NotBlocked() public {
        vm.prank(admin);
        yzusd.grantRole(THROTTLE_EXEMPT_ROLE, exempt);

        // Exempt receiver is never stamped, so a same-block redeem is allowed
        vm.prank(exempt);
        yzusd.deposit(100e6, exempt);
        assertEq(yzusd.lastMintBlock(exempt), 0);

        vm.prank(exempt);
        yzusd.withdraw(50e6, exempt, exempt);
    }

    function test_SameBlock_ZeroAmountMint_DoesNotStamp() public {
        // user holds a redeemable position from an earlier block
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1);

        // A zero-amount deposit or mint from `other` to `user` does not stamp user for the current block
        vm.prank(other);
        yzusd.deposit(0, user);
        assertTrue(yzusd.lastMintBlock(user) != block.number);
        vm.prank(other);
        yzusd.mint(0, user);
        assertTrue(yzusd.lastMintBlock(user) != block.number);

        // So user's same-block redeem is not blocked
        vm.prank(user);
        yzusd.withdraw(50e6, user, user);
    }
}
