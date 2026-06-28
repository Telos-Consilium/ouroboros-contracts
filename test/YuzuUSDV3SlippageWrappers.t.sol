// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../src/YuzuUSDV3Facet.sol";

contract USDT0Mock is ERC20Mock {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice The slippage-guarded redemption wrappers must work on the proxy.
/// @dev withdrawWithSlippage/redeemWithSlippage are inherited from YuzuIssuer and call the public
/// withdraw/redeem. The proxy overrides withdraw/redeem to forward to the facet via a calldata
/// trampoline; if that trampoline forwards the outer wrapper selector, the facet (which only implements
/// withdraw/redeem) reverts and the slippage path is unreachable. Plain withdraw/redeem are asserted as
/// a control so a failure isolates to the wrappers.
contract YuzuUSDV3SlippageWrappersTest is Test {
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");

    USDT0Mock asset;
    YuzuUSDV3 yzusd;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address user = makeAddr("user");

    function setUp() public {
        asset = new USDT0Mock();
        asset.mint(user, 10_000_000e6);

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

        vm.prank(user);
        yzusd.deposit(1_000e6, user);
        vm.roll(block.number + 1); // clear the same-block guard so instant redemption is allowed
    }

    function test_Redeem_Succeeds_Control() public {
        uint256 shares = yzusd.balanceOf(user) / 2;
        vm.prank(user);
        uint256 assets = yzusd.redeem(shares, user, user);
        assertGt(assets, 0);
    }

    function test_RedeemWithSlippage_Succeeds() public {
        uint256 shares = yzusd.balanceOf(user) / 2;
        vm.prank(user);
        uint256 assets = yzusd.redeemWithSlippage(shares, user, user, 0);
        assertGt(assets, 0);
    }

    function test_WithdrawWithSlippage_Succeeds() public {
        vm.prank(user);
        uint256 tokens = yzusd.withdrawWithSlippage(100e6, user, user, type(uint256).max);
        assertGt(tokens, 0);
    }
}
