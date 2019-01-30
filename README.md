# Haskoin Store

Full blockchain index & store featuring:

- Bitcoin Cash (BCH) & Bitcoin SegWit (BTC) support.
- Address balance, transaction, and UTXO index.
- Mempool support (SPV).
- XPub balance, transaction, and UTXO support.
- Persistent storage using RocksDB.
- RESTful endpoints for blockchain data.
- Concurrent non-blocking transactional design.
- Guaranteed consistency within a request.


## Install

* Get [Stack](https://haskell-lang.org/get-started).
* Get [Nix](https://nixos.org/nix/).
* Clone this repository `git clone https://github.com/haskoin/haskoin-store`.
* From the root of this repository run `stack --nix build --copy-bins`.
* File will usually be installed in `~/.local/bin/haskoin-store`.


## API Documentation

* [Swagger API Documentation](https://btc.haskoin.com/).

## Notes

### Transaction Ordering
Transactions are returned in reverse blockchain or mempool order, meaning that the latest transactions are shown first, starting from the mempool and then from the highest block in the blockchain. If many transactions are returned from the same block, they are in reverse order as they appear in the block, meaning the latest transaction in the block comes first.

After the November 2018 hard fork Bitcoin Cash transactions are not stored in a block in topological order. If multiple transactions in one block depend on each other, they may appear in the "wrong" order. This is intentional and does not need to be fixed.
