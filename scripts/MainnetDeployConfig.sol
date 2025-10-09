// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/*
 * USDT0 on Plasma
 */

address constant UNDERLYING_ASSET = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

/*
 * Roles
 */

address constant SUPER_ADMIN = 0xa2a9700407934e913C840556B3D29F19cf6f203d;
address constant PROXY_ADMIN_OWNER = SUPER_ADMIN;

address constant ADMIN = 0xe61ad2De346db42879B6ee3c7cF0C6a2cDC0530d;
address constant LIMIT_MANAGER = ADMIN;
address constant REDEEM_MANAGER = ADMIN;
address constant POOL_MANAGER = ADMIN;
address constant RESTRICTION_MANAGER = ADMIN;

address constant YZUSD_ORDER_FILLER = 0x0879Aa9e47d3209Ce36aDDCf6561196040A73d8f;
address constant YZILP_ORDER_FILLER = 0x8d8d4441F1E7dbF05d0e4448f2dd635BEC0a478d;

address constant YZUSD_PAUSE_MANAGER = 0x0879Aa9e47d3209Ce36aDDCf6561196040A73d8f;
address constant YZILP_PAUSE_MANAGER = 0x8d8d4441F1E7dbF05d0e4448f2dd635BEC0a478d;

/*
 * YuzuUSD
 */

string constant YZUSD_NAME = "Yuzu USD";
string constant YZUSD_SYMBOL = "yzUSD";
address constant YZUSD_ADMIN = SUPER_ADMIN; // [ignore]
address constant YZUSD_TREASURY = 0x0879Aa9e47d3209Ce36aDDCf6561196040A73d8f;
address constant YZUSD_FEE_RECEIVER = 0x88f025C01dc457B3A627B83614daC587D40759a1;
uint256 constant YZUSD_SUPPLY_CAP = type(uint256).max; // No supply cap
uint256 constant YZUSD_FILL_WINDOW = 1_209_600; // 14 days
uint256 constant YZUSD_MIN_REDEEM_ORDER = 50_000e18;

uint256 constant YZUSD_REDEEM_FEE_PPM = 3_000; // 0.3%
uint256 constant YZUSD_REDEEM_ORDER_FEE_PPM = 0; // [ignored]
bool constant YZUSD_IS_MINT_RESTRICTED = true;
bool constant YZUSD_IS_REDEEM_RESTRICTED = true;
uint256 constant YZUSD_LIQUIDITY_BUFFER_TARGET_SIZE = 0; // [ignored]

/*
 * YuzuILP
 */

string constant YZILP_NAME = "Yuzu Protection Pool";
string constant YZILP_SYMBOL = "yzPP";
address constant YZILP_ADMIN = SUPER_ADMIN; // [ignore]
address constant YZILP_TREASURY = 0x8d8d4441F1E7dbF05d0e4448f2dd635BEC0a478d;
address constant YZILP_FEE_RECEIVER = 0x88f025C01dc457B3A627B83614daC587D40759a1;
uint256 constant YZILP_SUPPLY_CAP = 0; // Not mintable
uint256 constant YZILP_FILL_WINDOW = 1_209_600; // 14 days
uint256 constant YZILP_MIN_REDEEM_ORDER = 50_000e18;

uint256 constant YZILP_REDEEM_FEE_PPM = 0; // [ignored]
uint256 constant YZILP_REDEEM_ORDER_FEE_PPM = 0; // [ignored]
bool constant YZILP_IS_MINT_RESTRICTED = true;
bool constant YZILP_IS_REDEEM_RESTRICTED = true;
uint256 constant YZILP_LIQUIDITY_BUFFER_TARGET_SIZE = 0; // [ignored]

/*
 * StakedYuzuUSD
 */

string constant SYZUSD_NAME = "Staked Yuzu USD";
string constant SYZUSD_SYMBOL = "syzUSD";
address constant SYZUSD_OWNER = 0xe61ad2De346db42879B6ee3c7cF0C6a2cDC0530d;
address constant SYZUSD_FEE_RECEIVER = 0x88f025C01dc457B3A627B83614daC587D40759a1;
uint256 constant SYZUSD_REDEEM_DELAY = 86_400; // 24 hours

uint256 constant SYZUSD_UNSTAKE_FEE_PPM = 0; // [ignored]
