// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Roles
bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 constant BURNER_ROLE = keccak256("BURNER_ROLE");
bytes32 constant DELAY_EXEMPT_ROLE = keccak256("DELAY_EXEMPT_ROLE");
bytes32 constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
bytes32 constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
bytes32 constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
bytes32 constant MARKDOWN_STEP_EXEMPT_ROLE = keccak256("MARKDOWN_STEP_EXEMPT_ROLE");
bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
bytes32 constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");
bytes32 constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
bytes32 constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
bytes32 constant PRICE_GUARD_MANAGER_ROLE = keccak256("PRICE_GUARD_MANAGER_ROLE");
bytes32 constant REDEEM_FEE_EXEMPT_ROLE = keccak256("REDEEM_FEE_EXEMPT_ROLE");
bytes32 constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
bytes32 constant SAME_BLOCK_EXEMPT_ROLE = keccak256("SAME_BLOCK_EXEMPT_ROLE");
bytes32 constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

// Protocol bounds
/// @dev Maximum management fee, in ppm per year (10%)
uint256 constant MAX_MANAGEMENT_FEE_PPM = 100_000;
/// @dev Maximum performance fee, in ppm (50%)
uint256 constant MAX_PERFORMANCE_FEE_PPM = 500_000;
