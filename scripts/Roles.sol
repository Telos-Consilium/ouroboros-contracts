// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");
bytes32 constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
bytes32 constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
bytes32 constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
bytes32 constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");
bytes32 constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

bytes32 constant MINTER_ROLE = keccak256("MINTER_ROLE");
bytes32 constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");
