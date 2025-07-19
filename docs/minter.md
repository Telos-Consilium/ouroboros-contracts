# YuzuUSDMinter Contract

## Overview

The YuzuUSDMinter contract is a minting and redemption system that allows users to mint YuzuUSD tokens by depositing collateral and redeem collateral by burning YuzuUSD tokens. The contract implements three distinct redemption mechanisms with different speed, cost, and risk characteristics.

## Core Concepts

### 1. Collateral-Backed Minting
- **1:1 Collateral Ratio**: Each YuzuUSD token is backed by exactly 1 unit of collateral token (e.g. USDC)
- **Treasury Model**: Collateral is transferred to a treasury address upon minting
- **Permissionless Minting**: Anyone can mint YuzuUSD by providing collateral (subject to rate limits)

### 2. Three-Tier Redemption System
1. **Instant Redeem**: Immediate redemption using contract's liquidity buffer
2. **Fast Redeem**: Order-based redemption with 24h (default) fulfillment window
3. **Standard Redeem**: Order-based redemption with 7-day (default) fulfillment window

### 3. Role-Based Access Control
The contract uses OpenZeppelin's AccessControl with hierarchical role management:

- **DEFAULT_ADMIN_ROLE**: Ultimate admin with emergency powers
- **ADMIN_ROLE**: Can manage other roles and critical settings
- **LIMIT_MANAGER_ROLE**: Can adjust minting/redemption limits
- **REDEEM_MANAGER_ROLE**: Can configure redemption parameters and fees
- **ORDER_FILLER_ROLE**: Can fulfill pending fast redemption orders

## Contract Architecture

### State Variables

#### Immutable Configuration
```solidity
IYuzuUSD public immutable yzusd;           // YuzuUSD token contract
address public immutable collateralToken;  // Collateral ERC20 token
```

#### Mutable Configuration
```solidity
address public treasury;                  // Receives collateral from minting
address public redeemFeeRecipient;        // Receives redemption fees
uint256 public maxMintPerBlock;           // Per-block mint limit
uint256 public maxRedeemPerBlock;         // Per-block instant redeem limit
```

#### Fee Configuration (in Parts Per Million)
```solidity
uint256 public instantRedeemFeePpm = 0;   // Instant redemption fee
uint256 public fastRedeemFeePpm = 0;      // Fast redemption fee  
uint256 public standardRedeemFeePpm = 0;  // Standard redemption fee
```

#### Time Windows
```solidity
uint256 public fastFillWindow = 1 days;     // Fast order fulfillment deadline
uint256 public standardFillWindow = 7 days; // Standard order fulfillment deadline
```

#### Order Management
```solidity
mapping(uint256 => Order) internal fastRedeemOrders;       // Fast redeem orders
mapping(uint256 => Order) internal standardRedeemOrders;   // Standard redeem orders
uint256 public fastRedeemOrderCount = 0;                   // Fast order counter
uint256 public standardRedeemOrderCount = 0;               // Standard order counter
```

#### Pending Value Tracking
```solidity
uint256 public currentPendingFastRedeemValue = 0;     // Total pending fast redemptions
uint256 public currentPendingStandardRedeemValue = 0; // Total pending standard redemptions
```

#### Rate Limiting
```solidity
mapping(uint256 => uint256) public mintedPerBlock;   // Minted amount per block
mapping(uint256 => uint256) public redeemedPerBlock; // Redeemed amount per block
```

### Order Structure

```solidity
struct Order {
    uint256 amount;         // Amount of YuzuUSD to redeem
    address owner;          // Order creator and beneficiary
    uint32 feePpm;          // Fee rate (locked at order creation)
    uint40 dueTime;         // When order becomes due
    OrderStatus status;     // Pending, Filled, or Cancelled
}

enum OrderStatus {
    Pending,    // Order created, awaiting fulfillment
    Filled,     // Order successfully completed
    Cancelled   // Order cancelled (expired fast orders)
}
```

Storing `feePpm` and `dueTime` as `uint32` and `uint40`, respectively, makes the `Order` struct fit in two 32-byte storage slots, reducing gas costs for storage operations.

## Core Mechanics

### 1. Minting Mechanism

#### Function: `mint(address to, uint256 amount)`

**Purpose**: Mint YuzuUSD tokens by depositing collateral

**Requirements**:
- `amount > 0`
- Caller must have approved contract to spend `amount` of collateral tokens
- `mintedPerBlock[currentBlock] + amount <= maxMintPerBlock`

**Process**:
1. **Validation**: Check amount > 0 and per-block limit
2. **Rate Limiting**: Update `mintedPerBlock[block.number]`
3. **Collateral Transfer**: Transfer collateral from caller to treasury
4. **Token Minting**: Mint YuzuUSD tokens to specified recipient
5. **Event Emission**: Emit `Minted(from, to, amount)`

**Edge Cases**:
- **Zero Amount**: Reverts with `InvalidAmount()`
- **Rate Limit Exceeded**: Reverts with `MaxMintPerBlockExceeded()`
- **Insufficient Allowance**: Reverts from ERC20 transfer
- **Insufficient Balance**: Reverts from ERC20 transfer

### 2. Instant Redemption Mechanism

#### Function: `instantRedeem(address to, uint256 amount)`

**Purpose**: Immediately redeem collateral for YuzuUSD using contract's liquidity buffer

**Requirements**:
- `amount > 0`
- Caller must have approved contract to spend `amount` of YuzuUSD tokens
- `redeemedPerBlock[currentBlock] + amount <= maxRedeemPerBlock`
- `amount <= contract's collateral balance` (liquidity buffer)

**Process**:
1. **Validation**: Check amount > 0, per-block limit, and liquidity buffer
2. **Rate Limiting**: Update `redeemedPerBlock[block.number]`
3. **Fee Calculation**: `fee = Math.mulDiv(amount, instantRedeemFeePpm, 1e6, Math.Rounding.Ceil)`
4. **Token Burning**: Burn YuzuUSD tokens from caller
5. **Collateral Transfer**: Transfer `amount - fee` to recipient
6. **Fee Transfer**: Transfer fee to `redeemFeeRecipient` (if fee > 0 and recipient ≠ contract)
7. **Event Emission**: Emit `InstantRedeem()` and `Redeemed()` events

**Liquidity Buffer**:
- **Source**: Contract's collateral token balance
- **Purpose**: Enables instant redemptions without waiting for order fulfillment
- **Management**: Replenished by admin via collateral deposits

**Fee Mechanism**:
- **Rate**: Configurable from 0-1000000 ppm (0-100%)
- **Calculation**: `fee = Math.mulDiv(amount, feePpm, 1e6, Math.Rounding.Ceil)`
- **Distribution**: Fee sent to `redeemFeeRecipient`
- **Exception**: If `redeemFeeRecipient == address(this)`, fee stays in contract as part of the liquidity buffer

**Edge Cases**:
- **Zero Amount**: Reverts with `InvalidAmount()`
- **Rate Limit Exceeded**: Reverts with `MaxRedeemPerBlockExceeded()`
- **Insufficient Liquidity**: Reverts with `LiquidityBufferExceeded()`
- **Insufficient YuzuUSD**: Reverts from ERC20 burn

### 3. Fast Redemption Mechanism

Fast redemption is a two-phase process: order creation and order fulfillment. Unlike instant and standard redeems, fast redeems are not rate limited by `maxRedeemPerBlock`.

#### Phase 1: Order Creation - `createFastRedeemOrder(uint256 amount)`

**Purpose**: Create a fast redemption order with 24-hour (default) fulfillment window

**Requirements**:
- `amount > 0`
- Caller must have approved contract to spend `amount` of YuzuUSD tokens

**Process**:
1. **Validation**: Check amount > 0
2. **Token Escrow**: Transfer YuzuUSD from caller to contract
3. **Order Creation**: Create order with:
   - `amount`: Specified amount
   - `owner`: Caller address
   - `feePpm`: Current `fastRedeemFeePpm`
   - `dueTime`: `block.timestamp + fastFillWindow`
   - `status`: Pending
4. **Tracking Updates**: 
   - Increment `fastRedeemOrderCount`
   - Add amount to `currentPendingFastRedeemValue`
5. **Event Emission**: Emit `FastRedeemOrderCreated(orderId, owner, amount)`

#### Phase 2: Order Fulfillment - `fillFastRedeemOrder(uint256 orderId, address feeRecipient)`

**Purpose**: Fulfill a fast redemption order by providing collateral

**Requirements**:
- Caller must have `ORDER_FILLER_ROLE`
- Order must exist (`order.amount > 0`)
- Order must be in `Pending` status
- Caller must have approved contract to spend collateral tokens

**Process**:
1. **Order Validation**: Check order exists and is pending
2. **Fee Calculation**: `fee = Math.mulDiv(order.amount, order.feePpm, 1e6, Math.Rounding.Ceil)`
3. **Token Burning**: Burn escrowed YuzuUSD tokens
4. **Collateral Transfer**: Transfer `amount - fee` from filler to order owner
5. **Fee Transfer**: Transfer fee from filler to `feeRecipient` (if fee > 0 and recipient ≠ filler)
6. **Order Update**: Set status to `Filled`
7. **Tracking Update**: Subtract amount from `currentPendingFastRedeemValue`
8. **Event Emission**: Emit `FastRedeemOrderFilled()` and `Redeemed()` events

**Time Constraints**:
- **Fill Window**: Default 24 hours (`fastFillWindow`)
- **Post-Expiration**: Order owners have the option, but not the obligation, of canceling an order once the fulfillment window has passed without the order being filled
- **No Early Fill Restriction**: Orders can be filled immediately after creation
- **Late Fill Allowed**: Orders can still be filled after the fill window expires (until cancelled by owner)

**Fee Mechanism**:
- **Rate**: Configurable from 0-1000000 ppm (0-100%)
- **Calculation**: `fee = Math.mulDiv(amount, feePpm, 1e6, Math.Rounding.Ceil)`
- **Distribution**: Fee sent to `feeRecipient`, not the necessarily the contract's `redeemFeeRecipient`
- **Exception**: If `feeRecipient == msg.sender`, the filler keeps the fee in the form of unsent collateral

**Edge Cases**:
- **Invalid Order**: Reverts with `InvalidOrder()` if order doesn't exist
- **Non-Pending Order**: Reverts with `OrderNotPending()`
- **Insufficient Collateral**: Reverts from ERC20 transfer

### 4. Standard Redemption Mechanism

Standard redemption is a two-phase process: order creation and order fulfillment. Like instant redemption, it uses the contract's liquidity buffer to fill orders.

#### Phase 1: Order Creation - `createStandardRedeemOrder(uint256 amount)`

**Purpose**: Create a standard redemption order with 7-day (default) fulfillment window

**Requirements**:
- `amount > 0`
- Caller must have approved contract to spend `amount` of YuzuUSD tokens
- `redeemedPerBlock[currentBlock] + amount <= maxRedeemPerBlock`

**Process**:
1. **Validation**: Check amount > 0 and per-block limit
2. **Rate Limiting**: Update `redeemedPerBlock[block.number]`
3. **Token Escrow**: Transfer YuzuUSD from caller to contract
4. **Order Creation**: Create order with:
   - `amount`: Specified amount
   - `owner`: Caller address
   - `feePpm`: Current `standardRedeemFeePpm`
   - `dueTime`: `block.timestamp + standardFillWindow`
   - `status`: Pending
5. **Tracking Updates**: 
   - Increment `standardRedeemOrderCount`
   - Add amount to `currentPendingStandardRedeemValue`
6. **Event Emission**: Emit `StandardRedeemOrderCreated(orderId, owner, amount)`

#### Phase 2: Order Fulfillment - `fillStandardRedeemOrder(uint256 orderId)`

**Purpose**: Fulfill a standard redemption order using contract's liquidity

**Requirements**:
- Order must exist (`order.amount > 0`)
- Order must be in `Pending` status
- `block.timestamp >= order.dueTime` (order must be due)
- `order.amount <= contract's liquidity buffer`

**Process**:
1. **Order Validation**: Check order exists and is pending
2. **Time Validation**: Check order is due (`block.timestamp >= dueTime`)
3. **Liquidity Check**: Ensure sufficient collateral in contract
4. **Fee Calculation**: `fee = Math.mulDiv(order.amount, order.feePpm, 1e6, Math.Rounding.Ceil)`
5. **Token Burning**: Burn escrowed YuzuUSD tokens
6. **Collateral Transfer**: Transfer `amount - fee` from contract to order from the liquidity buffer
7. **Fee Transfer**: Transfer fee to `redeemFeeRecipient` (if fee > 0 and recipient ≠ contract)
8. **Order Update**: Set status to `Filled`
9. **Tracking Update**: Subtract amount from `currentPendingStandardRedeemValue`
10. **Event Emission**: Emit `StandardRedeemOrderFilled()` and `Redeemed()` events

**Key Differences from Fast Redemption**:
- **Automatic Fulfillment**: Uses contract's liquidity, no external filler needed
- **Time Lock**: Cannot be filled until `dueTime` is reached
- **Rate Limited**: Order creation counts against `maxRedeemPerBlock`
- **Liquidity Dependent**: Requires sufficient collateral in contract
- **Permissionless**: Order fulfillment can be triggered by anyone

**Edge Cases**:
- **Invalid Order**: Reverts with `InvalidOrder()` if order doesn't exist
- **Non-Pending Order**: Reverts with `OrderNotPending()`
- **Not Due**: Reverts with `OrderNotDue()` if filled before `dueTime`
- **Insufficient Liquidity**: Reverts with `LiquidityBufferExceeded()`

## Administrative Functions

### Treasury Management

#### `setTreasury(address newTreasury)`
- **Role**: `ADMIN_ROLE`
- **Purpose**: Update treasury address that receives minted collateral
- **Validation**: `newTreasury != address(0)`
- **Event**: `TreasuryUpdated(oldTreasury, newTreasury)`

#### `setRedeemFeeRecipient(address newRecipient)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Update address that receives redemption fees
- **Validation**: `newRecipient != address(0)`
- **Event**: `RedeemFeeRecipientUpdated(oldRecipient, newRecipient)`

#### `withdrawCollateral(uint256 amount, address to)`
- **Role**: `DEFAULT_ADMIN_ROLE`
- **Purpose**: Withdraw excess collateral not reserved for pending redemptions
- **Calculation**: `outstandingBalance = balance - currentPendingStandardRedeemValue`
- **Validation**: `amount <= outstandingBalance`
- **Error**: `OutstandingBalanceExceeded()` if amount too large
- **Event**: `CollateralWithdrawn(to, amount)`

### Rate Limit Management

#### `setMaxMintPerBlock(uint256 newMaxMintPerBlock)`
- **Role**: `LIMIT_MANAGER_ROLE`
- **Purpose**: Adjust per-block minting limit
- **Validation**: None (can be set to 0 to pause minting)
- **Event**: `MaxMintPerBlockUpdated(oldMax, newMax)`

#### `setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock)`
- **Role**: `LIMIT_MANAGER_ROLE`
- **Purpose**: Adjust per-block instant/standard redemption limit
- **Validation**: None (can be set to 0 to pause instant redemptions)
- **Event**: `MaxRedeemPerBlockUpdated(oldMax, newMax)`

### Fee Management

#### `setInstantRedeemFeePpm(uint256 newFeePpm)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Set instant redemption fee rate
- **Range**: 0-1000000 ppm (0-100%)
- **Event**: `InstantRedeemFeePpmUpdated(oldFee, newFee)`

#### `setFastRedeemFeePpm(uint256 newFeePpm)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Set fast redemption fee rate
- **Range**: 0-1000000 ppm (0-100%)
- **Event**: `FastRedeemFeePpmUpdated(oldFee, newFee)`
- **Note**: Only affects new orders, existing orders use locked rate

#### `setStandardRedeemFeePpm(uint256 newFeePpm)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Set standard redemption fee rate
- **Range**: 0-1000000 ppm (0-100%)
- **Event**: `StandardRedeemFeePpmUpdated(oldFee, newFee)`
- **Note**: Only affects new orders, existing orders use locked rate

### Time Window Management

#### `setFastFillWindow(uint256 newWindow)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Set fast redemption fulfillment window
- **Units**: Seconds
- **Event**: `FastFillWindowUpdated(oldWindow, newWindow)`
- **Note**: Only affects new orders

#### `setStandardFillWindow(uint256 newWindow)`
- **Role**: `REDEEM_MANAGER_ROLE`
- **Purpose**: Set standard redemption fulfillment window
- **Units**: Seconds
- **Event**: `StandardFillWindowUpdated(oldWindow, newWindow)`
- **Note**: Only affects new orders

## Emergency Functions

### Asset Recovery

#### `rescueOutstandingYuzuUSD(uint256 amount, address to)`
- **Role**: `DEFAULT_ADMIN_ROLE`
- **Purpose**: Rescue YuzuUSD tokens not being escrowed for pending orders
- **Calculation**: `outstandingBalance = balance - pendingFast - pendingStandard`
- **Validation**: `amount <= outstandingBalance`
- **Error**: `OutstandingBalanceExceeded()` if amount too large

#### `rescueTokens(address token, uint256 amount, address to)`
- **Role**: `DEFAULT_ADMIN_ROLE`
- **Purpose**: Rescue accidentally sent tokens
- **Restriction**: Cannot rescue collateral tokens or YuzuUSD tokens
- **Validation**: `token != collateralToken && token != address(yzusd)`
- **Error**: `InvalidToken()` if restricted token

## Liquidity Management

### Liquidity Buffer
The contract maintains a collateral token balance that serves as a liquidity buffer for instant and standard redemptions.

#### Sources of Liquidity
1. **Admin Deposits**: Direct transfers to contract address
2. **Retained Fees**: When `redeemFeeRecipient == address(this)`
3. **Emergency Injection**: Admin can transfer collateral to contract

#### Liquidity Utilization
1. **Instant Redemptions**: Immediate consumption
2. **Standard Redemptions**: Delayed consumption after due time
3. **Admin Withdrawals**: Extraction of excess liquidity

#### Liquidity Calculations
```solidity
// Total liquidity buffer
function _getLiquidityBufferSize() internal view returns (uint256) {
    return IERC20(collateralToken).balanceOf(address(this));
}

// Available for admin withdrawal
function _getOutstandingCollateralBalance() internal view returns (uint256) {
    uint256 balance = IERC20(collateralToken).balanceOf(address(this));
    return balance - currentPendingStandardRedeemValue;
}
```

#### Fast Redemption Tracking
- **Increment**: When fast redeem order created
- **Decrement**: When fast redeem order filled or cancelled
- **Purpose**: Track total YuzuUSD tokens held in escrow

#### Standard Redemption Tracking
- **Increment**: When standard redeem order created
- **Decrement**: When standard redeem order filled
- **Purpose**: Reserve collateral for automatic fulfillment

## Usage Patterns

### Typical User Flows

#### Minting Flow
1. User approves collateral token spending
2. User calls `mint(to, amount)`
3. Collateral transferred to treasury
4. YuzuUSD minted to recipient

#### Instant Redemption Flow
1. User approves YuzuUSD spending
2. User calls `instantRedeem(to, amount)`
3. YuzuUSD burned from user
4. Collateral transferred to recipient (minus fees)

#### Fast Redemption Flow
1. **Order Creation**:
   - User approves YuzuUSD spending
   - User calls `createFastRedeemOrder(amount)`
   - YuzuUSD escrowed in contract
2. **Order Fulfillment**:
   - Filler approves collateral spending
   - Filler calls `fillFastRedeemOrder(orderId, feeRecipient)`
   - Collateral transferred to user (minus fees)

#### Standard Redemption Flow
1. **Order Creation**:
   - User approves YuzuUSD spending
   - User calls `createStandardRedeemOrder(amount)`
   - YuzuUSD escrowed in contract
2. **Order Fulfillment** (after due time):
   - Anyone calls `fillStandardRedeemOrder(orderId)`
   - Collateral transferred from contract to user (minus fees)

## Monitoring and Analytics

### Key Metrics

#### Volume Metrics
- `mintedPerBlock[blockNumber]`: Minting volume per block
- `redeemedPerBlock[blockNumber]`: Instant/standard redemption volume per block
- Total order counts: `fastRedeemOrderCount`, `standardRedeemOrderCount`

#### Liquidity Metrics
- Current liquidity buffer: `IERC20(collateralToken).balanceOf(address(this))`
- Pending commitments: `currentPendingFastRedeemValue`, `currentPendingStandardRedeemValue`
- Available liquidity: Buffer minus pending standard redemptions

## Deployment Considerations

### Constructor Parameters
Careful selection of initial parameters is critical:

- **Treasury**: Should be multisig or DAO-controlled
- **Fee Recipient**: May be same as treasury or separate revenue address
- **Rate Limits**: Should allow normal operation but prevent abuse
- **Admin Address**: Should be multisig for decentralization

### Initial Configuration
Post-deployment setup should include:

1. Role assignment to appropriate addresses
2. Initial liquidity provision to contract
3. Fee and rate limit configuration
