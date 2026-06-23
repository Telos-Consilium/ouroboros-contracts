// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV2} from "../src/YuzuILPV2.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {IYuzuProtoDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuILPV3FeesTest is Test, IYuzuProtoDefinitions, IYuzuILPV3Definitions {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");

    USDT0Mock asset;
    YuzuILPV3 yzilp;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address feeManager = makeAddr("feeManager");
    address redeemManager = makeAddr("redeemManager");
    address user = makeAddr("user");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);

        address impl = address(new YuzuILPV3());
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
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
        yzilp = YuzuILPV3(proxy);
        YuzuILPV2(proxy).reinitialize();
        yzilp.reinitializeV3();

        vm.startPrank(admin);
        yzilp.grantRole(FEE_MANAGER_ROLE, feeManager);
        yzilp.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
    }

    function _setMintFee(uint256 ppm) internal {
        vm.prank(feeManager);
        yzilp.setMintFee(ppm);
    }

    // --- mint fee on the deposit/mint paths ---

    function test_MintFee_DefaultsToZero() public {
        assertEq(yzilp.mintFeePpm(), 0);

        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);
        assertEq(shares, 100e18);
        assertEq(asset.balanceOf(feeReceiver), 0);
    }

    function test_MintFee_OnDeposit() public {
        _setMintFee(100_000); // 10%

        // 110 in: 10 fee to receiver, 100 net backing 100e18 shares
        vm.prank(user);
        uint256 shares = yzilp.deposit(110e6, user);
        assertEq(shares, 100e18);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
    }

    function test_MintFee_OnMint() public {
        _setMintFee(100_000); // 10%

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 paid = yzilp.mint(100e18, user);

        // 100 net for the shares + 10 fee on top
        assertEq(paid, 110e6);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
        assertEq(balBefore - asset.balanceOf(user), 110e6);
    }

    function test_SetMintFee_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedMintFee(0, 100_000);
        _setMintFee(100_000);
        assertEq(yzilp.mintFeePpm(), 100_000);
    }

    function test_SetMintFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1e6 + 1, 1e6));
        yzilp.setMintFee(1e6 + 1);
    }

    function test_SetMintFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setMintFee(100_000);
    }

    // --- redeem fee setters re-homed onto FEE_MANAGER_ROLE ---

    function test_SetRedeemFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemFee(5_000);
        assertEq(yzilp.redeemFeePpm(), 5_000);
    }

    function test_SetRedeemFee_Revert_RedeemManagerRejected() public {
        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemFee(5_000);
    }

    function test_SetRedeemOrderFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemOrderFee(3_000);
        assertEq(yzilp.redeemOrderFeePpm(), 3_000);

        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemOrderFee(3_000);
    }

    // --- feeReceiver stays under ADMIN_ROLE ---

    function test_SetFeeReceiver_StaysAdmin() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        yzilp.setFeeReceiver(newReceiver);
        assertEq(yzilp.feeReceiver(), newReceiver);
    }

    function test_SetFeeReceiver_Revert_FeeManagerRejected() public {
        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, ADMIN_ROLE)
        );
        yzilp.setFeeReceiver(makeAddr("newReceiver"));
    }

    function test_FeeManagerRole_AdminIsAdminRole() public view {
        assertEq(yzilp.getRoleAdmin(FEE_MANAGER_ROLE), ADMIN_ROLE);
    }
}
