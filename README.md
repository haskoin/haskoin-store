# Haskoin Store

Block chain store and index featuring:

- Persistent storage using [RocksDB](https://rocksdb.org/).
- [Bitcoin Cash (BCH)](https://www.bitcoincash.org/) support.
- [Bitcoin Core (BTC)](https://bitcoin.org/) support.
- Indices for address balances, transactions, and unspent outputs (UTXO).
- Persistent mempool.
- Replace Bitcoin Core (BTC) RBF transactions by default.
- Query transactions, balances and UTXO on extended keys (xpub).
- Optional accelerated xpub cache using Redis.
- RESTful API with JSON and binary serialization.
- High performance concurrent architecture.
- Compatibility with Blockchain.info-style endpoints.

## Install with Nix on any distribution

* Get [Nix](https://nixos.org/nix/)

```sh
nix-env --install stack
git clone https://github.com/haskoin/haskoin-store.git
cd haskoin-store
stack --nix build --copy-bins
~/.local/bin/haskoin-store --help
```

## Install on Ubuntu or Debian

```sh
apt install git zlib1g-dev libsecp256k1-dev librocksdb-dev pkg-config haskell-stack
git clone https://github.com/haskoin/haskoin-store.git
cd haskoin-store
stack build --copy-bins
~/.local/bin/haskoin-store --help
```

## Install on Fedora

```sh
dnf install git zlib-devel libsecp256k1-devel rocksdb-devel stack
git clone https://github.com/haskoin/haskoin-store.git
cd haskoin-store
stack build --copy-bins
~/.local/bin/haskoin-store --help
```

## Non-Haskell Dependencies

* [zlib](https://zlib.net/)
* [libsecp256k1](https://github.com/Bitcoin-ABC/secp256k1)
* [RocksDB](https://github.com/facebook/rocksdb)

## API Documentation

* [Swagger API Documentation](https://api.haskoin.com/)
