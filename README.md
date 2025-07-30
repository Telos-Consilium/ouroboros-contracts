# YuzuUSD

## Contracts

### YuzuUSD.sol

YuzuUSD is a simple ERC‑20 token used throughout the Yuzu protocol and backed 1:1 by another asset.

[YuzuUSD.sol docs](./docs/yzusd.md)

### YuzuUSDMinter.sol

The YuzuUSDMinter contract is a minting and redemption system that allows users to mint YuzuUSD tokens by depositing collateral and redeem collateral by burning YuzuUSD tokens.

[YuzuUSDMinter.sol docs](./docs/minter.md)

### StakedYuzuUSD.sol

StakedYuzuUSD is an ERC‑4626 vault that allows users to stake their yzUSD tokens.

[StakedYuzuUSD.sol docs](./docs/staked.md)

### YuzuILP.sol

YuzuILP is an ERC‑4626 vault representing deposits in the Yuzu Insurance Liquidity Pool.

[YuzuILP.sol docs](./docs/ilp.md)

---

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
