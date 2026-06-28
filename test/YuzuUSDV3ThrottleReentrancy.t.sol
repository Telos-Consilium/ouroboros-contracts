// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../src/YuzuUSDV3Facet.sol";

/// @dev Asset whose transferFrom re-enters the vault once, simulating a transfer-hook collateral.
contract ReentrantAsset is ERC20Mock {
    YuzuUSDV3 public vault;
    address public receiver;
    uint256 public reenterAmount;
    bool private entered;

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function arm(YuzuUSDV3 _vault, address _receiver, uint256 _amount) external {
        vault = _vault;
        receiver = _receiver;
        reenterAmount = _amount;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!entered && address(vault) != address(0)) {
            entered = true;
            vault.deposit(reenterAmount, receiver);
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice The per-block mint throttle must hold under re-entrancy. Throttle usage is consumed only after
/// the router transfers assets and mints, so a transfer-hook asset can re-enter deposit while usage still
/// reads zero. The budget is nonetheless enforced because _consumeMintThrottle reverts when cumulative
/// per-block usage exceeds the limit: the re-entrant nested mint consumes first, then the outer consume of
/// the combined amount exceeds the block limit and reverts, unwinding the whole transaction.
contract YuzuUSDV3ThrottleReentrancyTest is Test {
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");

    ReentrantAsset asset;
    YuzuUSDV3 yzusd;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address feeReceiver = makeAddr("feeReceiver");
    address user = makeAddr("user");

    function setUp() public {
        asset = new ReentrantAsset();
        asset.mint(user, 10_000_000e6);
        asset.mint(address(asset), 10_000_000e6); // funds the re-entrant nested deposit

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
        yzusd.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzusd.setMintThrottle(100e6, type(uint256).max); // 100e6 per block
        yzusd.setIsMintRestricted(false);
        yzusd.setIsRedeemRestricted(false);
        vm.stopPrank();

        vm.prank(user);
        asset.approve(proxy, type(uint256).max);
        vm.prank(address(asset));
        asset.approve(proxy, type(uint256).max);
    }

    function test_MintThrottle_NotBypassableViaReentrancy() public {
        // 60e6 outer + 60e6 re-entrant = 120e6 to `user` in one block, over the 100e6 block limit.
        asset.arm(yzusd, user, 60e6);
        vm.prank(user);
        vm.expectRevert(); // nested deposit must exceed the remaining budget and revert
        yzusd.deposit(60e6, user);
    }
}
