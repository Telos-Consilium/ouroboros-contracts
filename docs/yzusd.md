# YuzuUSD Contract

## Overview

YuzuUSD is a simple ERC‑20 token used throughout the Yuzu protocol and backed 1:1 by another asset. It extends OpenZeppelin's ERC20 implementation with permit support and an externally controlled minter. The owner manages the minter address and can transfer ownership using a two‑step process.

## Core Concepts

### 1. Minting Authority
- Only the address set as `minter` can call `mint` to create new tokens.
- The minter address is updated via `setMinter(address newMinter)` and an event `MinterUpdated` is emitted.

### 2. Ownership
- The contract inherits `Ownable2Step`, allowing secure ownership transfers via `transferOwnership` and `acceptOwnership`.
- Only the owner may change the minter.

## Contract Functions

### Minting
```solidity
function mint(address to, uint256 amount) external;
```
Mints `amount` tokens to `to`. Reverts if the caller is not the current minter.

### Burning
Inherited functions `burn` and `burnFrom` allow holders or approved accounts to destroy tokens.

### Administrative
- `setMinter(address newMinter)` sets the authorized minter.
- Ownership management functions: `transferOwnership`, `acceptOwnership`, and `renounceOwnership` from `Ownable2Step`.

## Deployment Considerations
Deploy the token with a name, symbol and initial owner. After deployment the owner should set a trusted minter contract to control supply.