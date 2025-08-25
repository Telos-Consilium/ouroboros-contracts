# YuzuUSD

## Contracts

### YuzuUSD.sol

YuzuUSD is an ERC‑20 token used throughout the Yuzu protocol and backed 1:1 by USDC.

### StakedYuzuUSD.sol

StakedYuzuUSD is an ERC‑4626 vault that allows users to stake YuzuUSD.

### YuzuILP.sol

YuzuILP is an ERC‑20 token representing deposits in the Yuzu Insurance Liquidity Pool (ILP).

## Mint and redemption mechanisms

### YuzuUSD and YuzuILP

Tokens are minted with:

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 tokens, address receiver) external returns (uint256 assets);
```

Tokens can be instantly redeemed with:

```solidity
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
function redeem(uint256 tokens, address receiver, address owner) external returns (uint256 assets);
```

Deposited assets are sent to an external treasury.

When redeeming with `withdraw` or `redeem`, withdrawn assets are sourced from the contract's liquidity buffer, which the admin funds from the treasury.

Users can also redeem tokens by creating redemption orders that are filled by the admin using external liquidity.

Orders are created, filled, and finalized with:

```solidity
function createRedeemOrder(uint256 tokens, address receiver, address owner) external returns (uint256 orderId, uint256 assets);
function fillRedeemOrder(uint256 orderId) external;
function finalizeRedeemOrder(uint256 orderId) external;
```

If the admin fails to fill an order within a configurable period, the order managers (either the token owner or the order creator) may cancel the order with:

```solidity
function cancelRedeemOrder(uint256 orderId) external;
```

### StakedYuzuUSD

Tokens are minted with:

```solidity
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function mint(uint256 tokens, address receiver) external returns (uint256 assets);
```

Redeems are performed in two steps with a configurable delay between them:

```solidity
function initiateRedeem(uint256 shares, address receiver, address owner) external returns (uint256, uint256);
function finalizeRedeem(uint256 orderId) external;
```

## Token value

### YuzuUSD

#### Mint

YuzuUSD tokens are minted 1:1 for the underlying asset (after decimal adjustment).

#### Redeem

YuzuUSD tokens are redeemable 1:1 for the underlying asset, subject to a configurable fee or incentive.

### YuzuILP

YuzuILP tokens represent a share of the insurance liquidity pool (ILP). The ILP size is periodically updated by the admin, who also sets a yield rate when updating the pool.

#### Mint

Tokens are priced according to the share of the ILP they represent, including the yield accrued since the last pool-size update.

#### Redeem

Tokens are priced according to the share of the ILP they represent, excluding the yield accrued since the last pool-size update. In other words, yield accrued after the last update is forfeited when redeeming tokens.

Excluding recently accrued yield prevents an exploiter from depositing assets immediately after an update and withdrawing them before the next update, thereby capturing most of the yield without bearing the pool's risk.

A configurable fee or incentive may apply to redeems.

### StakedYuzuUSD

#### Mint

Tokens are priced according to the share of YuzuUSD held by the contract that they represent.

#### Redeem

Redeem pricing follows the same rules as minting, and a configurable fee may apply.

## Redemption fees

### YuzuUSD and YuzuILP

Instant redeems are subject to a configurable fee. Redeem orders can either be charged a fee or receive an incentive.

### StakedYuzuUSD

Redeems are subject to a configurable fee.
