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


## Install

* Get [Stack](https://haskell-lang.org/get-started).
* Get [Nix](https://nixos.org/nix/).

```sh
git clone https://github.com/haskoin/haskoin-store.git
stack --nix build --copy-bins
~/.local/bin/haskoin-store --help
```
## API Documentation

* [Swagger API Documentation](https://api.haskoin.com/).
