# Haskoin Store

Full blockchain index & store featuring:

- Bitcoin Cash (BCH) & Bitcoin SegWit (BTC) support.
- Address balance, transaction, and UTXO index.
- Mempool support (SPV).
- XPub balance, transaction, and UTXO support.
- Persistent storage using RocksDB.
- RESTful endpoints for blockchain data.
- Concurrent non-blocking transactional design.
- JSON and Protocol Buffers serialization support.


## Install

* Get [Stack](https://haskell-lang.org/get-started).
* Get [Nix](https://nixos.org/nix/).
* Clone this repository `git clone https://github.com/haskoin/haskoin-store`.
* From the root of this repository run `stack --nix build --copy-bins`.
* File will usually be installed in `~/.local/bin/haskoin-store`.

## Cache

A memory-based RocksDB database can be used as a cache to store:

* Address balances.
* Unspent outputs.

Give `haskoin-store` the path to a directory mapped to RAM, and it will be used to create a RockDB database for caching. Needs at least 30 GB


## API Documentation

* [Swagger API Documentation](https://btc.haskoin.com/).
