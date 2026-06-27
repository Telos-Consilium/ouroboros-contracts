// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3FeatureFacet} from "../src/YuzuUSDV3FeatureFacet.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {YuzuILPV3} from "../src/YuzuILPV3.sol";
import {YuzuILPV3FeatureFacet} from "../src/YuzuILPV3FeatureFacet.sol";
import {IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract YuzuV3MinAmountsTest is Test, IYuzuMinAmountsDefinitions {
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");

    USDT0Mock asset;
    YuzuUSDV3 yzusd;
    YuzuILPV3 yzilp;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address limitManager = makeAddr("limitManager");
    address user = makeAddr("user");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);

        yzusd = YuzuUSDV3(
            _deploy(address(new YuzuUSDV3(address(new YuzuUSDV3FeatureFacet()))), YuzuUSD.initialize.selector)
        );
        yzilp = YuzuILPV3(
            _deploy(address(new YuzuILPV3(address(new YuzuILPV3FeatureFacet()))), YuzuILP.initialize.selector)
        );

        // V3 carries the throttle; seed limits to unlimited so min-amount paths are reachable
        yzusd.reinitializeV3();
        yzilp.reinitializeV3();

        vm.startPrank(user);
        asset.approve(address(yzusd), type(uint256).max);
        asset.approve(address(yzilp), type(uint256).max);
        vm.stopPrank();
    }

    function _deploy(address impl, bytes4 initSelector) internal returns (address) {
        bytes memory initData = abi.encodeWithSelector(
            initSelector, address(asset), "Token", "TKN", admin, treasury, feeReceiver, type(uint256).max, 1 days, 0
        );
        address proxy = address(new ERC1967Proxy(impl, initData));
        vm.startPrank(admin);
        IAccessControl(proxy).grantRole(LIMIT_MANAGER_ROLE, limitManager);
        IAccessControl(proxy).grantRole(REDEEM_MANAGER_ROLE, admin);
        (bool ok,) = proxy.call(abi.encodeWithSignature("setIsMintRestricted(bool)", false));
        require(ok, "setIsMintRestricted");
        (ok,) = proxy.call(abi.encodeWithSignature("setIsRedeemRestricted(bool)", false));
        require(ok, "setIsRedeemRestricted");
        vm.stopPrank();
        return proxy;
    }

    // Setters

    function test_SetMinDeposit_Revert_NotLimitManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, LIMIT_MANAGER_ROLE)
        );
        yzusd.setMinDeposit(10e6);
    }

    function test_SetMinDeposit_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit UpdatedMinDeposit(0, 10e6);
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);
        assertEq(yzusd.minDeposit(), 10e6);
    }

    // yzUSD instant paths

    function test_YuzUSD_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.deposit(5e6, user);

        vm.prank(user);
        yzusd.deposit(10e6, user); // at the floor, succeeds
    }

    function test_YuzUSD_Mint_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzusd.setMinDeposit(10e6);

        uint256 shares = yzusd.previewDeposit(5e6); // worth 5e6 assets
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzusd.mint(shares, user);
    }

    function test_YuzUSD_Withdraw_Revert_UnderMinWithdraw() public {
        // Fund the instant liquidity buffer so maxWithdraw is non-zero
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);
        vm.roll(block.number + 1); // same-block guard: redeem in a later block than the mint

        vm.prank(limitManager);
        yzusd.setMinWithdraw(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinWithdraw.selector, 5e6, 10e6));
        yzusd.withdraw(5e6, user, user);

        vm.prank(user);
        yzusd.withdraw(10e6, user, user); // at the floor, succeeds
    }

    // yzILP mint path

    function test_YuzILP_Deposit_Revert_UnderMinDeposit() public {
        vm.prank(limitManager);
        yzilp.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UnderMinDeposit.selector, 5e6, 10e6));
        yzilp.deposit(5e6, user);

        vm.prank(user);
        yzilp.deposit(10e6, user); // at the floor, succeeds
    }

    // Min floor reflected in the ERC-4626 max views (clamped to 0 when remaining capacity is below the floor)

    function test_YuzUSD_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzusd.setMinDeposit(10e6);
        yzusd.setMintThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzusd.maxDeposit(user), 0);
        assertEq(yzusd.maxMint(user), 0);
    }

    function test_YuzUSD_MaxWithdraw_ClampedToZero_BelowMinFloor() public {
        vm.prank(admin);
        yzusd.setLiquidityBufferTargetSize(1_000_000e6);
        vm.prank(user);
        yzusd.deposit(100e6, user);

        vm.startPrank(limitManager);
        yzusd.setMinWithdraw(10e6);
        yzusd.setRedeemThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzusd.maxWithdraw(user), 0);
        assertEq(yzusd.maxRedeem(user), 0);
    }

    function test_YuzILP_MaxDeposit_ClampedToZero_BelowMinFloor() public {
        vm.startPrank(limitManager);
        yzilp.setMinDeposit(10e6);
        yzilp.setMintThrottle(5e6, type(uint256).max); // remaining below the floor
        vm.stopPrank();

        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);
    }
}
