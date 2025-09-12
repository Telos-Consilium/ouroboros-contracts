# YuzuUSD

## Contracts

### YuzuUSD.sol

YuzuUSD is an ERC‑20 token used throughout the Yuzu protocol and backed 1:1 by USDC.

### StakedYuzuUSD.sol

StakedYuzuUSD is an ERC‑4626 vault that allows users to stake YuzuUSD.

### YuzuILP.sol

YuzuILP is an ERC‑20 token representing USDC deposits in the Yuzu Insurance Liquidity Pool (ILP).

## Minting tokens

For all three contracts, tokens are minted with:

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 tokens, address receiver) external returns (uint256 assets);
```

- YuzuUSD and YuzuILP deposits (USDC) are sent to an external treasury.
- StakedYuzuUSD deposits (YuzuUSD) are held in the vault contract.

## Redeeming tokens

### YuzuUSD

Tokens can be instantly redeemed with:

```solidity
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
function redeem(uint256 tokens, address receiver, address owner) external returns (uint256 assets);
```

When redeeming with `withdraw` or `redeem`, withdrawn assets are sourced from the contract's liquidity buffer, which the admin funds from the treasury.

Users can also redeem tokens by creating redemption orders that are filled by the admin using external liquidity.

Orders are created, filled, and finalized with:

```solidity
function createRedeemOrder(uint256 tokens, address receiver, address owner) external returns (uint256 orderId, uint256 assets);
function fillRedeemOrder(uint256 orderId) external;
function finalizeRedeemOrder(uint256 orderId) external;
```

If the admin fails to fill an order within a configurable period, the order manager (either the token owner or the order creator) may cancel the order with:

```solidity
function cancelRedeemOrder(uint256 orderId) external;
```

### YuzuILP

Instant redemptions are disabled.

Tokens can be redeemed with `createRedeemOrder()`, `fillRedeemOrder()`, and `finalizeRedeemOrder()`, and canceled with `cancelRedeemOrder()` like YuzuUSD.

### StakedYuzuUSD

Redemptions are performed in two steps with a configurable delay between them:

```solidity
function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256);
function finalizeRedeem(uint256 orderId) external;
```

## Token exchange rate

### YuzuUSD

#### Mint

YuzuUSD tokens are minted 1:1 for the underlying asset (after decimal adjustment).

#### Redeem

YuzuUSD tokens are redeemed 1:1 for the underlying asset, subject to a configurable fee.

### YuzuILP

YuzuILP tokens represent a pro rata claim on the insurance liquidity pool (ILP). The ILP size is periodically updated by the admin, who also sets a yield rate when updating the pool.

#### Mint

Tokens are priced according to the share of the ILP they represent, including all yield accrued so far.

#### Redeem

Same as minting, subject to a configurable fee.

The redemption price for an order is set when the order is filled. All yield accrued until that point is included in the price calculation.

### StakedYuzuUSD

StakedYuzuUSD tokens represent a pro rata claim on the YuzuUSD held by the vault.

#### Mint

Tokens are priced according to the share of the vault's YuzuUSD balance they represent, including all yield accrued so far.

#### Redeem

Same as minting, subject to a configurable fee.

The price is set when a redemption is initiated. All yield accrued until that point is counted toward the price calculation.
