// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

import "./MainnetDeployConfig.sol";
import "./Roles.sol";

address constant YZUSD_IMPLEMENTATION = address(0x90b1Bc26E1Ac873fC5043a9F658443dAAB674D85);
address constant YZILP_IMPLEMENTATION = address(0x7e8bc59B4126415c86C9Bf1f8Cb277B9D9249281);
address constant SYZUSD_IMPLEMENTATION = address(0xb14E7d488371D22D39AFF1b0C0F07Ed2b532160f);

contract Deploy is Script {
    YuzuUSD internal yzUSDProxy;
    YuzuILP internal yzILPProxy;
    StakedYuzuUSD internal stakedYzUSDProxy;

    address internal deploymentAdmin;

    function setUp() public {
        console.log("=== Preparing mainnet proxy deployment ===");
        console.log("Deploying from address:", msg.sender);
        console.log("Using config:");

        console.log("--------------------------------------------------");

        console.log("UNDERLYING_ASSET", UNDERLYING_ASSET);

        console.log("--------------------------------------------------");

        console.log("YZUSD Parameters:");
        console.log("YZUSD_NAME", YZUSD_NAME);
        console.log("YZUSD_SYMBOL", YZUSD_SYMBOL);
        console.log("YZUSD_ADMIN", YZUSD_ADMIN);
        console.log("YZUSD_TREASURY", YZUSD_TREASURY);
        console.log("YZUSD_FEE_RECEIVER", YZUSD_FEE_RECEIVER);
        console.log("YZUSD_SUPPLY_CAP", YZUSD_SUPPLY_CAP);
        console.log("YZUSD_FILL_WINDOW", YZUSD_FILL_WINDOW);
        console.log("YZUSD_MIN_REDEEM_ORDER", YZUSD_MIN_REDEEM_ORDER);
        console.log("YZUSD_REDEEM_FEE_PPM", YZUSD_REDEEM_FEE_PPM);
        console.log("YZUSD_REDEEM_ORDER_FEE_PPM", YZUSD_REDEEM_ORDER_FEE_PPM);
        console.log("YZUSD_IS_MINT_RESTRICTED", YZUSD_IS_MINT_RESTRICTED);
        console.log("YZUSD_IS_REDEEM_RESTRICTED", YZUSD_IS_REDEEM_RESTRICTED);
        console.log("YZUSD_LIQUIDITY_BUFFER_TARGET_SIZE", YZUSD_LIQUIDITY_BUFFER_TARGET_SIZE);

        console.log("--------------------------------------------------");

        console.log("YZILP Parameters:");
        console.log("YZILP_NAME", YZILP_NAME);
        console.log("YZILP_SYMBOL", YZILP_SYMBOL);
        console.log("YZILP_ADMIN", YZILP_ADMIN);
        console.log("YZILP_TREASURY", YZILP_TREASURY);
        console.log("YZILP_FEE_RECEIVER", YZILP_FEE_RECEIVER);
        console.log("YZILP_SUPPLY_CAP", YZILP_SUPPLY_CAP);
        console.log("YZILP_FILL_WINDOW", YZILP_FILL_WINDOW);
        console.log("YZILP_MIN_REDEEM_ORDER", YZILP_MIN_REDEEM_ORDER);
        console.log("YZILP_REDEEM_FEE_PPM", YZILP_REDEEM_FEE_PPM);
        console.log("YZILP_REDEEM_ORDER_FEE_PPM", YZILP_REDEEM_ORDER_FEE_PPM);
        console.log("YZILP_IS_MINT_RESTRICTED", YZILP_IS_MINT_RESTRICTED);
        console.log("YZILP_IS_REDEEM_RESTRICTED", YZILP_IS_REDEEM_RESTRICTED);
        console.log("YZILP_LIQUIDITY_BUFFER_TARGET_SIZE", YZILP_LIQUIDITY_BUFFER_TARGET_SIZE);

        console.log("--------------------------------------------------");

        console.log("SYZUSD Parameters:");
        console.log("SYZUSD_NAME", SYZUSD_NAME);
        console.log("SYZUSD_SYMBOL", SYZUSD_SYMBOL);
        console.log("SYZUSD_OWNER", SYZUSD_OWNER);
        console.log("SYZUSD_FEE_RECEIVER", SYZUSD_FEE_RECEIVER);
        console.log("SYZUSD_REDEEM_DELAY", SYZUSD_REDEEM_DELAY);
        console.log("SYZUSD_UNSTAKE_FEE_PPM", SYZUSD_UNSTAKE_FEE_PPM);
    }

    function run() public {
        console.log("=== Starting mainnet proxy deployment ===");

        deploymentAdmin = msg.sender;

        vm.startBroadcast();

        deployYuzuUSDProxy();
        configureYuzuUSD();
        grantRolesYuzuUSD();

        deployYuzuILPProxy();
        configureYuzuILP();
        grantRolesYuzuILP();

        deployStakedYuzuUSDProxy();

        vm.stopBroadcast();
    }

    function deployYuzuUSDProxy() internal {
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            UNDERLYING_ASSET,
            YZUSD_NAME,
            YZUSD_SYMBOL,
            deploymentAdmin,
            YZUSD_TREASURY,
            YZUSD_FEE_RECEIVER,
            YZUSD_SUPPLY_CAP,
            YZUSD_FILL_WINDOW,
            YZUSD_MIN_REDEEM_ORDER
        );

        TransparentUpgradeableProxy _yzUSDProxy =
            new TransparentUpgradeableProxy(address(YZUSD_IMPLEMENTATION), PROXY_ADMIN_OWNER, initData);
        yzUSDProxy = YuzuUSD(address(_yzUSDProxy));
    }

    function configureYuzuUSD() internal {
        yzUSDProxy.grantRole(REDEEM_MANAGER_ROLE, deploymentAdmin);
        yzUSDProxy.grantRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);

        yzUSDProxy.setRedeemFee(YZUSD_REDEEM_FEE_PPM);
        yzUSDProxy.setIsMintRestricted(YZUSD_IS_MINT_RESTRICTED);
        yzUSDProxy.setIsRedeemRestricted(YZUSD_IS_REDEEM_RESTRICTED);

        yzUSDProxy.revokeRole(REDEEM_MANAGER_ROLE, deploymentAdmin);
        yzUSDProxy.revokeRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);
    }

    function grantRolesYuzuUSD() internal {
        yzUSDProxy.grantRole(ADMIN_ROLE, ADMIN);

        yzUSDProxy.grantRole(LIMIT_MANAGER_ROLE, LIMIT_MANAGER);
        yzUSDProxy.grantRole(POOL_MANAGER_ROLE, POOL_MANAGER);
        yzUSDProxy.grantRole(RESTRICTION_MANAGER_ROLE, RESTRICTION_MANAGER);
        yzUSDProxy.grantRole(REDEEM_MANAGER_ROLE, REDEEM_MANAGER);

        yzUSDProxy.grantRole(ORDER_FILLER_ROLE, YZUSD_ORDER_FILLER);
        yzUSDProxy.grantRole(PAUSE_MANAGER_ROLE, YZUSD_PAUSE_MANAGER);
        yzUSDProxy.grantRole(PAUSE_MANAGER_ROLE, POOL_MANAGER);
    }

    function deployYuzuILPProxy() internal {
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            UNDERLYING_ASSET,
            YZILP_NAME,
            YZILP_SYMBOL,
            deploymentAdmin,
            YZILP_TREASURY,
            YZILP_FEE_RECEIVER,
            YZILP_SUPPLY_CAP,
            YZILP_FILL_WINDOW,
            YZILP_MIN_REDEEM_ORDER
        );

        TransparentUpgradeableProxy _yzILPProxy =
            new TransparentUpgradeableProxy(address(YZILP_IMPLEMENTATION), PROXY_ADMIN_OWNER, initData);
        yzILPProxy = YuzuILP(address(_yzILPProxy));
    }

    function configureYuzuILP() internal {
        yzILPProxy.grantRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);

        yzILPProxy.setIsMintRestricted(YZILP_IS_MINT_RESTRICTED);
        yzILPProxy.setIsRedeemRestricted(YZILP_IS_REDEEM_RESTRICTED);

        yzILPProxy.revokeRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);
    }

    function grantRolesYuzuILP() internal {
        yzILPProxy.grantRole(ADMIN_ROLE, ADMIN);

        yzILPProxy.grantRole(LIMIT_MANAGER_ROLE, LIMIT_MANAGER);
        yzILPProxy.grantRole(POOL_MANAGER_ROLE, POOL_MANAGER);
        yzILPProxy.grantRole(RESTRICTION_MANAGER_ROLE, RESTRICTION_MANAGER);
        yzILPProxy.grantRole(REDEEM_MANAGER_ROLE, REDEEM_MANAGER);

        yzILPProxy.grantRole(ORDER_FILLER_ROLE, YZILP_ORDER_FILLER);
        yzILPProxy.grantRole(PAUSE_MANAGER_ROLE, YZILP_PAUSE_MANAGER);
        yzILPProxy.grantRole(PAUSE_MANAGER_ROLE, POOL_MANAGER);
    }

    function deployStakedYuzuUSDProxy() internal {
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            address(yzUSDProxy),
            SYZUSD_NAME,
            SYZUSD_SYMBOL,
            SYZUSD_OWNER,
            SYZUSD_FEE_RECEIVER,
            SYZUSD_REDEEM_DELAY
        );

        TransparentUpgradeableProxy _stakedYzUSDProxy =
            new TransparentUpgradeableProxy(address(SYZUSD_IMPLEMENTATION), PROXY_ADMIN_OWNER, initData);
        stakedYzUSDProxy = StakedYuzuUSD(address(_stakedYzUSDProxy));
    }
}
