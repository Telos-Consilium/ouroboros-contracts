# StakedYuzuUSD Contract

## Overview

StakedYuzuUSD is an ERC‑4626 vault that allows users to stake their yzUSD tokens. Deposits mint shares that represent a claim on the vault's yzUSD balance. Withdrawals are not immediate; instead holders initiate a redeem order and finalize it after a configurable delay.

## Core Concepts

### 1. Delayed Redemption
- **Two‑Step Withdrawal**: Users call `initiateRedeem` to burn shares and start a redemption order. After `redeemDelay` elapses anyone may call `finalizeRedeem` to transfer the underlying yzUSD.
- **Per‑Block Limits**: Deposits and withdrawal requests are rate limited by `maxDepositPerBlock` and `maxWithdrawPerBlock`.
- **Order Tracking**: Each redemption creates an `Order` struct stored by ID. Pending asset commitments are tracked in `currentRedeemAssetCommitment` and excluded from `totalAssets()`.

### 2. Ownership
The contract uses `Ownable2StepUpgradeable`; the owner can adjust parameters and rescue tokens.

## Contract Architecture

### State Variables
```solidity
uint256 public redeemDelay;                 // Delay before finalization
uint256 public currentRedeemAssetCommitment; // Assets locked in pending redeems
uint256 public maxDepositPerBlock;          // Per‑block deposit limit
uint256 public maxWithdrawPerBlock;         // Per‑block withdrawal limit
mapping(uint256 => uint256) public depositedPerBlock;  // Deposits per block
mapping(uint256 => uint256) public withdrawnPerBlock;  // Withdrawals per block
mapping(uint256 => Order) internal redeemOrders;       // Redemption orders
uint256 public redeemOrderCount;            // Total number of orders
```

### Order Structure
```solidity
struct Order {
    uint256 assets;    // yzUSD amount to redeem
    uint256 shares;    // Shares burned
    address owner;     // Order creator
    uint40 dueTime;    // When finalization is allowed
    bool executed;     // If the order has been finalized
}
```

## Core Mechanics

### Deposits
- `deposit(uint256 assets, address receiver)` and `mint(uint256 shares, address receiver)` use the standard ERC‑4626 logic and update `depositedPerBlock`.
- Calls revert if the per‑block deposit limit would be exceeded.

### Redemption Workflow
1. **Initiate**: `initiateRedeem(uint256 shares)` burns the caller's shares, creates an order, records the assets committed and due time, and updates `withdrawnPerBlock`.
2. **Finalize**: `finalizeRedeem(uint256 orderId)` can be executed by anyone after `dueTime`. It transfers assets to the order owner and marks the order executed.

### Administrative Functions
- `setMaxDepositPerBlock(uint256 newMaxDepositPerBlock)` and `setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock)` adjust rate limits.
- `setRedeemDelay(uint256 newRedeemDelay)` changes the waiting period before finalization.
- `rescueTokens(address token, address to, uint256 amount)` lets the owner recover tokens other than yzUSD.

## Usage Notes
- Instant `withdraw` and `redeem` are disabled; the two‑step process must be used instead.
- `totalAssets()` excludes tokens committed to pending orders.
- Order details can be retrieved with `getRedeemOrder(uint256 orderId)`.

## Deployment Considerations
- Initialize with the yzUSD token address, token name and symbol, owner address, and rate limit parameters.
- The owner should be a trusted multisig able to adjust limits and redeem delay.