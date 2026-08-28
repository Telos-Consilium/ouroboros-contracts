// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Re-exported so every test imports role identifiers from one place
import {
    ADMIN_ROLE,
    BURNER_ROLE,
    DELAY_EXEMPT_ROLE,
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    MARKDOWN_STEP_EXEMPT_ROLE,
    MINTER_ROLE,
    NAV_MANAGER_ROLE,
    ORDER_FILLER_ROLE,
    PAUSE_MANAGER_ROLE,
    POOL_MANAGER_ROLE,
    PRICE_GUARD_MANAGER_ROLE,
    REDEEM_FEE_EXEMPT_ROLE,
    REDEEM_MANAGER_ROLE,
    SAME_BLOCK_EXEMPT_ROLE,
    THROTTLE_EXEMPT_ROLE
} from "../../src/libraries/YuzuV3Constants.sol";

// Roles declared internal in frozen contracts and the factory, re-derived here for tests
bytes32 constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");
bytes32 constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
bytes32 constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
bytes32 constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");
bytes32 constant USER_ROLE = keccak256("USER_ROLE");
