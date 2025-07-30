# YuzuILP Contract

## Overview

YuzuILP is an ERC‑4626 vault representing deposits in the Yuzu Insurance Liquidity Pool. Users deposit an ERC‑20 token and receive shares that track the size of the pool with a non‑compounding linear yield. Deposited assets are transferred to a treasury address and withdrawals are performed through delayed redeem orders that must be filled by an external order filler.

## Core Concepts

### 1. Tokenized Insurance Pool
- **Treasury Backing**: All deposits are moved to a treasury controlled outside the contract.
- **Linear Yield**: The pool manager periodically updates the pool size and a daily linear yield rate. The vault accrues yield linearly based on time since the last update.
- **Delayed Withdrawals**: Immediate withdrawals are disabled. Users create redeem orders that are later filled by an account with the `ORDER_FILLER_ROLE`.

### 2. Role‑Based Access
YuzuILP uses `AccessControlDefaultAdminRulesUpgradeable` with the following roles:
- `DEFAULT_ADMIN_ROLE`
- `ADMIN_ROLE`
- `LIMIT_MANAGER_ROLE`
- `ORDER_FILLER_ROLE`
- `POOL_MANAGER_ROLE`

## Contract Architecture

### State Variables
```solidity
IERC20 private _asset;                // Underlying asset token
address public treasury;             // Treasury receiving deposits
uint256 public poolSize;             // Current pool size
uint256 public withdrawAllowance;    // Total amount available to redeem
uint256 public dailyLinearYieldRatePpm; // Daily yield in ppm
uint256 public lastPoolUpdateTimestamp; // Timestamp of last pool update
uint256 public maxDepositPerBlock;   // Per‑block deposit limit
mapping(uint256 => uint256) public depositedPerBlock; // Deposits per block
mapping(uint256 => Order) internal redeemOrders;      // Pending redeem orders
uint256 public redeemOrderCount;     // Total number of orders
```

### Order Structure
```solidity
struct Order {
    uint256 assets;    // Amount of underlying to redeem
    uint256 shares;    // Shares burned
    address owner;     // Order creator
    bool executed;     // Redeem executed flag
}
```

## Core Mechanics

### Deposits and Minting
- `deposit(uint256 assets, address receiver)` and `mint(uint256 shares, address receiver)` transfer the underlying asset from the caller to the treasury and mint vault shares.
- Deposits are limited by `maxDepositPerBlock` using `depositedPerBlock[block.number]`.
- The pool size increases by the deposit amount discounted for yield since the last update.

### Redemption Workflow
1. **Create Order**: `createRedeemOrder(uint256 shares)` burns shares and creates an order. The order amount is calculated with `previewRedeem` and reduces `withdrawAllowance` and `poolSize`.
2. **Fill Order**: `fillRedeemOrder(uint256 orderId)` can only be called by an account with `ORDER_FILLER_ROLE`. The filler transfers assets to the owner and the order is marked executed.

### Pool Updates
- `updatePool(uint256 newPoolSize, uint256 newWithdrawalAllowance, uint256 newDailyLinearYieldRatePpm)` sets the pool parameters and records the current timestamp. Only addresses with `POOL_MANAGER_ROLE` may call it.

### Administrative Functions
- `setTreasury(address newTreasury)` updates the treasury address.
- `setMaxDepositPerBlock(uint256 newMaxDepositPerBlock)` adjusts the per block deposit limit.
- `rescueTokens(address token, address to, uint256 amount)` allows an admin to recover tokens other than the asset.

## Usage Notes
- Withdraw and redeem functions of ERC‑4626 are disabled; users must rely on the redeem order mechanism.
- Yield accrues linearly between pool updates based on `dailyLinearYieldRatePpm`.
- Order information can be queried using `getRedeemOrder(uint256 orderId)`.
- When redeeming shares for assets, the yield accrued since the last pool update is not included. This is to prevent actors from depositing and withdrawing in between pool updated to earn risk-free yield.

## Deployment Considerations
- Deploy with an initial admin and treasury.
- Grant `POOL_MANAGER_ROLE`, `ORDER_FILLER_ROLE`, and `LIMIT_MANAGER_ROLE` to appropriate operators or multisigs.