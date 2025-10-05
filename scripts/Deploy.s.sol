// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YuzuUSD} from "../src/YuzuUSD.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {StakedYuzuUSD} from "../src/StakedYuzuUSD.sol";

contract USDCMock is ERC20Mock {
    constructor() ERC20Mock() {}

    function decimals() public view virtual override returns (uint8) {
        return 6; // USDC has 6 decimals
    }
}

/**
 * @title Deploy
 * @dev Local deployment script for all Yuzu protocol contracts
 *
 * This script deploys all contracts in the correct order and initializes them
 * with sensible default parameters for local development and testing.
 *
 * Deployment order:
 * 1. Mock collateral token (USDC mock)
 * 2. YuzuUSD token
 * 3. YuzuILP (with proxy)
 * 4. StakedYuzuUSD (with proxy)
 *
 * Usage:
 * forge script scripts/Deploy.s.sol:Deploy --fork-url http://localhost:8545 --broadcast
 */
contract Deploy is Script {
    struct DeployParameters {
        address admin;
        address treasury;
        address redeemFeeRecipient;
        uint256 yuzuUsdSupplyCap;
        uint256 yuzuUsdFillWindow;
        uint256 yuzuUsdMinRedeemOrder;
        uint256 yzilpSupplyCap;
        uint256 yzilpFillWindow;
        uint256 yzilpMinRedeemOrder;
        uint256 yuzuUsdRedeemFee;
        uint256 yuzuUsdRedeemOrderFee;
        uint256 yzilpRedeemFee;
        uint256 yzilpRedeemOrderFee;
        uint256 stakedRedeemFee;
        uint256 stakedRedeemDelay;
        uint256 adminCollateralMint;
        uint256 liquidityBufferMint;
        string yuzuUsdName;
        string yuzuUsdSymbol;
        string yzilpName;
        string yzilpSymbol;
        string stakedName;
        string stakedSymbol;
    }

    string internal constant DEFAULT_DEPLOY_CONFIG_PATH = "config/.deploy.env";
    // Deployment addresses (will be set after deployment)
    address public collateralToken;
    address public yzusd;
    address public stakedYzusd;
    address public yzilp;

    // Configuration addresses
    address public admin;
    address public treasury;
    address public redeemFeeRecipient;

    DeployParameters internal params;

    function setUp() public {
        // Load parameters from configuration file with sensible defaults
        params = _loadDeployParameters();

        admin = params.admin;
        treasury = params.treasury;
        redeemFeeRecipient = params.redeemFeeRecipient;

        console.log("Deploying with admin/treasury:", admin);
    }

    function run() public {
        vm.startBroadcast();

        console.log("=== Starting Yuzu Protocol Deployment ===");

        // 1. Deploy mock collateral token (USDC)
        deployCollateralToken();

        // 2. Deploy YuzuUSD token
        deployYuzuUSD();

        // 3. Deploy YuzuILP
        deployYuzuILP();

        // 4. Deploy StakedYuzuUSD
        deployStakedYuzuUSD();

        // 5. Setup initial configurations
        setupInitialConfiguration();

        // 6. Log deployment summary
        logDeploymentSummary();

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
    }

    function deployCollateralToken() internal {
        console.log("\n1. Deploying mock collateral token (USDC)...");

        ERC20Mock mockUSDC = new USDCMock();
        collateralToken = address(mockUSDC);

        // Mint some tokens to admin for testing
        mockUSDC.mint(admin, params.adminCollateralMint);

        console.log("Collateral token deployed at:", collateralToken);
        console.log("Minted", params.adminCollateralMint, "USDC units (6 decimals) to admin");
    }

    function deployYuzuUSD() internal {
        console.log("\n2. Deploying YuzuUSD token...");

        // Deploy implementation
        YuzuUSD implementation = new YuzuUSD();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            collateralToken,
            params.yuzuUsdName,
            params.yuzuUsdSymbol,
            admin,
            treasury,
            redeemFeeRecipient,
            params.yuzuUsdSupplyCap,
            params.yuzuUsdFillWindow,
            params.yuzuUsdMinRedeemOrder
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        yzusd = address(proxy);

        // Fund liquidity buffer
        ERC20Mock(collateralToken).mint(yzusd, params.liquidityBufferMint);

        console.log(
            "YuzuUSD implementation deployed at:",
            address(implementation)
        );
        console.log("YuzuUSD proxy deployed at:", yzusd);
    }

    function deployYuzuILP() internal {
        console.log("\n3. Deploying YuzuILP...");

        // Deploy implementation
        YuzuILP implementation = new YuzuILP();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            collateralToken,
            params.yzilpName,
            params.yzilpSymbol,
            admin,
            treasury,
            redeemFeeRecipient,
            params.yzilpSupplyCap,
            params.yzilpFillWindow,
            params.yzilpMinRedeemOrder
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        yzilp = address(proxy);

        console.log(
            "YuzuILP implementation deployed at:",
            address(implementation)
        );
        console.log("YuzuILP proxy deployed at:", yzilp);
    }

    function deployStakedYuzuUSD() internal {
        console.log("\n4. Deploying StakedYuzuUSD...");

        // Deploy implementation
        StakedYuzuUSD implementation = new StakedYuzuUSD();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            StakedYuzuUSD.initialize.selector,
            IERC20(yzusd), // _asset
            params.stakedName,
            params.stakedSymbol,
            admin, // _owner
            redeemFeeRecipient,
            params.stakedRedeemDelay
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        stakedYzusd = address(proxy);

        console.log(
            "StakedYuzuUSD implementation deployed at:",
            address(implementation)
        );
        console.log("StakedYuzuUSD proxy deployed at:", stakedYzusd);
    }

    function setupInitialConfiguration() internal {
        console.log("\n5. Setting up initial configuration...");

        YuzuUSD usd = YuzuUSD(yzusd);
        YuzuILP ilp = YuzuILP(yzilp);
        StakedYuzuUSD staked = StakedYuzuUSD(stakedYzusd);

        // Grant necessary roles for testing
        bytes32 LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
        bytes32 ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
        bytes32 REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
        bytes32 POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

        usd.grantRole(LIMIT_MANAGER_ROLE, admin);
        usd.grantRole(ORDER_FILLER_ROLE, admin);
        usd.grantRole(REDEEM_MANAGER_ROLE, admin);
        console.log("Granted YuzuUSD roles to admin");

        ilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        ilp.grantRole(ORDER_FILLER_ROLE, admin);
        ilp.grantRole(REDEEM_MANAGER_ROLE, admin);
        ilp.grantRole(POOL_MANAGER_ROLE, admin);
        console.log("Granted YuzuILP roles to admin");

        usd.setRedeemFee(params.yuzuUsdRedeemFee);
        usd.setRedeemOrderFee(params.yuzuUsdRedeemOrderFee);
        usd.setIsMintRestricted(false);
        usd.setIsRedeemRestricted(false);
        console.log("Set YuzuUSD redeem fees");

        ilp.setRedeemFee(params.yzilpRedeemFee);
        ilp.setRedeemOrderFee(params.yzilpRedeemOrderFee);
        ilp.setIsMintRestricted(false);
        ilp.setIsRedeemRestricted(false);
        console.log("Set YuzuILP redeem fees");

        staked.setRedeemFee(params.stakedRedeemFee);
        console.log("Set StakedYuzuUSD redeem fee");
    }

    function logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Admin/Treasury/FeeRecipient:", admin);
        console.log("");
        console.log("Collateral Token (Mock USDC):", collateralToken);
        console.log("YuzuUSD Token:", yzusd);
        console.log("YuzuILP Proxy:", yzilp);
        console.log("StakedYuzuUSD Proxy:", stakedYzusd);
        console.log("");
        console.log("=== INITIAL CONFIGURATION ===");
        console.log("YuzuUSD supply cap:", params.yuzuUsdSupplyCap);
        console.log("YuzuUSD fill window:", params.yuzuUsdFillWindow);
        console.log("YuzuUSD min redeem order:", params.yuzuUsdMinRedeemOrder);
        console.log("YuzuILP supply cap:", params.yzilpSupplyCap);
        console.log("YuzuILP fill window:", params.yzilpFillWindow);
        console.log("YuzuILP min redeem order:", params.yzilpMinRedeemOrder);
        console.log("StakedYuzuUSD redeem delay:", params.stakedRedeemDelay);
        console.log("");
        console.log("=== TESTING SETUP ===");
        console.log("Admin has", params.adminCollateralMint/1_000_000, "mock USDC for testing");
        console.log("Admin has all necessary roles granted");
    }

    function _loadDeployParameters() internal returns (DeployParameters memory result) {
        string memory defaultPath = string.concat(vm.projectRoot(), "/", DEFAULT_DEPLOY_CONFIG_PATH);
        string memory configPath = vm.envOr("DEPLOY_CONFIG_PATH", defaultPath);

        result = DeployParameters({
            admin: msg.sender,
            treasury: msg.sender,
            redeemFeeRecipient: msg.sender,
            yuzuUsdSupplyCap: 1_000_000e18,
            yuzuUsdFillWindow: 604_800,
            yuzuUsdMinRedeemOrder: 0,
            yzilpSupplyCap: 1_000_000e18,
            yzilpFillWindow: 604_800,
            yzilpMinRedeemOrder: 0,
            yuzuUsdRedeemFee: 0,
            yuzuUsdRedeemOrderFee: 0,
            yzilpRedeemFee: 0,
            yzilpRedeemOrderFee: 0,
            stakedRedeemFee: 0,
            stakedRedeemDelay: 86_400,
            adminCollateralMint: 10_000e6,
            liquidityBufferMint: 10_000e6,
            yuzuUsdName: "Yuzu USD",
            yuzuUsdSymbol: "yzUSD",
            yzilpName: "Yuzu Insurance Liquidity Pool",
            yzilpSymbol: "yzILP",
            stakedName: "Staked Yuzu USD",
            stakedSymbol: "st-yzUSD"
        });

        result.admin = _readAddressOrDefault(configPath, "ADMIN", result.admin);
        result.treasury = _readAddressOrDefault(configPath, "TREASURY", result.treasury);
        result.redeemFeeRecipient = _readAddressOrDefault(
            configPath,
            "REDEEM_FEE_RECIPIENT",
            result.redeemFeeRecipient
        );

        result.yuzuUsdSupplyCap = _readUintOrDefault(configPath, "YUZUSD_SUPPLY_CAP", result.yuzuUsdSupplyCap);
        result.yuzuUsdFillWindow = _readUintOrDefault(configPath, "YUZUSD_FILL_WINDOW", result.yuzuUsdFillWindow);
        result.yuzuUsdMinRedeemOrder = _readUintOrDefault(
            configPath,
            "YUZUSD_MIN_REDEEM_ORDER",
            result.yuzuUsdMinRedeemOrder
        );

        result.yzilpSupplyCap = _readUintOrDefault(configPath, "YZILP_SUPPLY_CAP", result.yzilpSupplyCap);
        result.yzilpFillWindow = _readUintOrDefault(configPath, "YZILP_FILL_WINDOW", result.yzilpFillWindow);
        result.yzilpMinRedeemOrder = _readUintOrDefault(
            configPath,
            "YZILP_MIN_REDEEM_ORDER",
            result.yzilpMinRedeemOrder
        );

        result.yuzuUsdRedeemFee = _readUintOrDefault(configPath, "YUZUSD_REDEEM_FEE", result.yuzuUsdRedeemFee);
        result.yuzuUsdRedeemOrderFee = _readUintOrDefault(
            configPath,
            "YUZUSD_REDEEM_ORDER_FEE",
            result.yuzuUsdRedeemOrderFee
        );
        result.yzilpRedeemFee = _readUintOrDefault(configPath, "YZILP_REDEEM_FEE", result.yzilpRedeemFee);
        result.yzilpRedeemOrderFee = _readUintOrDefault(
            configPath,
            "YZILP_REDEEM_ORDER_FEE",
            result.yzilpRedeemOrderFee
        );

        result.stakedRedeemFee = _readUintOrDefault(configPath, "STAKED_REDEEM_FEE", result.stakedRedeemFee);
        result.stakedRedeemDelay = _readUintOrDefault(
            configPath,
            "STAKED_REDEEM_DELAY",
            result.stakedRedeemDelay
        );

        result.adminCollateralMint = _readUintOrDefault(
            configPath,
            "ADMIN_COLLATERAL_MINT",
            result.adminCollateralMint
        );
        result.liquidityBufferMint = _readUintOrDefault(
            configPath,
            "LIQUIDITY_BUFFER_MINT",
            result.liquidityBufferMint
        );

        result.yuzuUsdName = _readStringOrDefault(configPath, "YUZUSD_NAME", result.yuzuUsdName);
        result.yuzuUsdSymbol = _readStringOrDefault(configPath, "YUZUSD_SYMBOL", result.yuzuUsdSymbol);
        result.yzilpName = _readStringOrDefault(configPath, "YZILP_NAME", result.yzilpName);
        result.yzilpSymbol = _readStringOrDefault(configPath, "YZILP_SYMBOL", result.yzilpSymbol);
        result.stakedName = _readStringOrDefault(configPath, "STAKED_NAME", result.stakedName);
        result.stakedSymbol = _readStringOrDefault(configPath, "STAKED_SYMBOL", result.stakedSymbol);
    }

    function _readEnvValue(string memory path, string memory key) internal returns (string memory) {
        string memory command = string.concat(
            "set -a; if [ -f \"",
            path,
            "\" ]; then source \"",
            path,
            "\"; fi; set +a; printf '%s' \"${",
            key,
            "}\""
        );

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-lc";
        inputs[2] = command;

        bytes memory raw = vm.ffi(inputs);
        return _trim(string(raw));
    }

    function _readAddressOrDefault(string memory path, string memory key, address defaultValue)
        internal
        returns (address)
    {
        string memory raw = _readEnvValue(path, key);
        if (bytes(raw).length == 0) {
            return defaultValue;
        }
        return vm.parseAddress(raw);
    }

    function _readUintOrDefault(string memory path, string memory key, uint256 defaultValue)
        internal
        returns (uint256)
    {
        string memory raw = _readEnvValue(path, key);
        if (bytes(raw).length == 0) {
            return defaultValue;
        }
        return vm.parseUint(raw);
    }

    function _readStringOrDefault(string memory path, string memory key, string memory defaultValue)
        internal
        returns (string memory)
    {
        string memory raw = _readEnvValue(path, key);
        if (bytes(raw).length == 0) {
            return defaultValue;
        }
        return raw;
    }

    function _trim(string memory value) internal pure returns (string memory) {
        bytes memory data = bytes(value);
        uint256 start = 0;
        uint256 end = data.length;

        while (start < data.length && _isWhitespace(data[start])) {
            start++;
        }

        while (end > start && _isWhitespace(data[end - 1])) {
            end--;
        }

        if (start == 0 && end == data.length) {
            return value;
        }

        bytes memory trimmed = new bytes(end - start);
        for (uint256 i = 0; i < trimmed.length; i++) {
            trimmed[i] = data[start + i];
        }
        return string(trimmed);
    }

    function _isWhitespace(bytes1 char) internal pure returns (bool) {
        return char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D;
    }
}
