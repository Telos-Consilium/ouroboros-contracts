# Ouroboros Contracts

Foundry repository for the Yuzu Money protocol contracts.

## Contracts

- `YuzuUSD`: treasury-backed stablecoin with instant and order-based redemption paths.
- `StakedYuzuUSD`: staking vault for `YuzuUSD`.
- `YuzuILP`: share token for the protection pool.
- `PSM`: atomic conversion module with a dedicated redemption liquidity pool.

## Layout

- `src/`: core contracts and interfaces.
- `test/`: unit, integration, and feature tests.
- `ci/`: CI helpers.

## Getting Started

```bash
git clone --recurse-submodules <repo>
```

## Commands

```bash
make fmt-check
make test
make test-invariants
make build-production
make check-submodules
```
