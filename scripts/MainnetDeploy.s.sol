// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ProxyAdmin} from "lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

import "./MainnetDeployConfig.sol";

bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
bytes32 constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
bytes32 constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
bytes32 constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
bytes32 constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");
bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
bytes32 constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

contract Deploy is Script {
    ProxyAdmin internal proxyAdmin;
    YuzuUSD internal yzUSD;
    YuzuILP internal yzILP;
    StakedYuzuUSD internal stakedYzUSD;

    address internal deploymentAdmin;

    function setUp() public {
        console.log("=== Preparing mainnet deployment ===");
        console.log("Deploying from address:", msg.sender);
        console.log("Using config:");

        console.log("--------------------------------------------------");

        console.log("UNDERLYING_ASSET", UNDERLYING_ASSET);
        console.log("PROXY_ADMIN", PROXY_ADMIN_OWNER);
        
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
        console.log("=== Starting mainnet deployment ===");

        deploymentAdmin = msg.sender;

        vm.startBroadcast();

        deployProxyAdmin();

        deployYuzuUSD();
        configureYuzuUSD();
        grantRolesYuzuUSD();

        deployYuzuILP();
        configureYuzuILP();
        grantRolesYuzuILP();

        deployStakedYuzuUSD();

        vm.stopBroadcast();
    }

    function deployProxyAdmin() internal {
        proxyAdmin = new ProxyAdmin(PROXY_ADMIN_OWNER);
    }

    function deployYuzuUSD() internal {
        YuzuUSD implementation = new YuzuUSD();

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

        TransparentUpgradeableProxy yzUSDProxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        yzUSD = YuzuUSD(address(yzUSDProxy));
    }

    function configureYuzuUSD() internal {
        yzUSD.grantRole(REDEEM_MANAGER_ROLE, deploymentAdmin);
        yzUSD.grantRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);

        yzUSD.setRedeemFee(YZUSD_REDEEM_FEE_PPM);
        yzUSD.setIsMintRestricted(YZUSD_IS_MINT_RESTRICTED);
        yzUSD.setIsRedeemRestricted(YZUSD_IS_REDEEM_RESTRICTED);

        yzUSD.revokeRole(REDEEM_MANAGER_ROLE, deploymentAdmin);
        yzUSD.revokeRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);
    }

    function grantRolesYuzuUSD() internal {
        yzUSD.grantRole(ADMIN_ROLE, ADMIN);

        yzUSD.grantRole(LIMIT_MANAGER_ROLE, LIMIT_MANAGER);
        yzUSD.grantRole(POOL_MANAGER_ROLE, POOL_MANAGER);
        yzUSD.grantRole(RESTRICTION_MANAGER_ROLE, RESTRICTION_MANAGER);

        yzUSD.grantRole(ORDER_FILLER_ROLE, YZUSD_ORDER_FILLER);
        yzUSD.grantRole(PAUSE_MANAGER_ROLE, YZUSD_PAUSE_MANAGER);
        yzUSD.grantRole(PAUSE_MANAGER_ROLE, POOL_MANAGER);
    }

    function deployYuzuILP() internal {
        YuzuILP implementation = new YuzuILP();

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

        TransparentUpgradeableProxy yzILPProxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        yzILP = YuzuILP(address(yzILPProxy));
    }

    function configureYuzuILP() internal {
        yzILP.grantRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);

        yzILP.setIsMintRestricted(YZUSD_IS_MINT_RESTRICTED);
        yzILP.setIsRedeemRestricted(YZUSD_IS_REDEEM_RESTRICTED);

        yzILP.revokeRole(RESTRICTION_MANAGER_ROLE, deploymentAdmin);
    }

    function grantRolesYuzuILP() internal {
        yzILP.grantRole(ADMIN_ROLE, ADMIN);
        
        yzILP.grantRole(LIMIT_MANAGER_ROLE, LIMIT_MANAGER);
        yzILP.grantRole(POOL_MANAGER_ROLE, POOL_MANAGER);
        yzILP.grantRole(RESTRICTION_MANAGER_ROLE, RESTRICTION_MANAGER);

        yzILP.grantRole(ORDER_FILLER_ROLE, YZILP_ORDER_FILLER);
        yzILP.grantRole(PAUSE_MANAGER_ROLE, YZILP_PAUSE_MANAGER);
        yzILP.grantRole(PAUSE_MANAGER_ROLE, POOL_MANAGER);
    }

    function deployStakedYuzuUSD() internal {
        /*
         * Staked YuzuUSD does not have a configuration step. So it is deployed with it's rightful owner.
         */
        StakedYuzuUSD implementation = new StakedYuzuUSD();

        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            address(yzUSD),
            SYZUSD_NAME,
            SYZUSD_SYMBOL,
            SYZUSD_OWNER,
            SYZUSD_FEE_RECEIVER,
            SYZUSD_REDEEM_DELAY
        );

        TransparentUpgradeableProxy stakedYzUSDProxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        );
        stakedYzUSD = StakedYuzuUSD(address(stakedYzUSDProxy));
    }
}
