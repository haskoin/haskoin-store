# Haskoin Store

Full block store and index featuring:

- Persistent storage using the [RocksDB](https://rocksdb.org/) engine.
- [Bitcoin Cash](https://www.bitcoincash.org/) (BCH) support.
- [Bitcoin Segwit](httsp://bitcoin.org/) (BTC) support.
- Indices for address balances, transactions, and unspent outputs (UTXO).
- Persistent mempool.
- Allow replacing BTC RBF transactions on mempool.
- Query transactions, balances and UTXO on extended keys (xpub).
- Optional accelerated xpub cache using Redis.
- REST API (mostly).
- High-performance concurrent architecture.
- Support for both JSON and binary formats.

## Quick Install with Nix Anywhere

* Get [Nix](https://nixos.org/nix/).

```sh
nix-env --install stack
git clone https://github.com/haskoin/haskoin-store.git
cd haskoin-store
stack --nix build --copy-bins
~/.local/bin/haskoin-store --help
```

## Install on Ubuntu 20.04

* Get [Stack](https://haskellstack.org/)

```sh
apt install git libsecp256k1-dev librocksdb-dev
git clone https://github.com/haskoin/haskoin-store.git
cd haskoin-store
stack build --copy-bins
~/.local/bin/haskoin-store --help
```

## Non-Haskell Dependencies

* [libsecp256k1](https://github.com/Bitcoin-ABC/secp256k1)
* [RocksDB](https://github.com/facebook/rocksdb/)

## API Documentation

* [Swagger API Documentation](https://api.haskoin.com/).
