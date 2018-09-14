# Haskoin Store

Full blockchain index & store featuring:

- Address index.
- Mempool.
- Persistent storage using RocksDB.
- RESTful endpoints for blockchain data.
- Concurrent design.
- No blocking on database access.
- Guaranteed consistency within a request.
- Atomic updates to prevent corruption.


## Install

* Get [Stack](https://haskell-lang.org/get-started).
* Get [Nix](https://nixos.org/nix/).
* Clone this repository `git clone https://github.com/haskoin/haskoin-store`.
* From the root of this repository run `stack --nix build --copy-bins`.
* File will usually be installed in `~/.local/bin/haskoin-store`.


## API Documentation

* [Swagger API Documentation](https://btc.haskoin.com/).


## Addresses & Balances

For every address Haskoin Store has a balance object that contains basic statistics about the address. These statistics are described below.

* `confirmed` balance is that which is in the blockchain. Will always be positive or zero.
* `unconfirmed` balance represent aggregate changes done by mempool transactions. Can be negative if the transactions currently in the mempool are expected to reduce the balance when all of them make it into the blockchain.
* `outputs` is the count of outputs that send funds to this address. It is just a count and not a monetary value.
* `utxo` is the count of outputs that send funds to this address that remain unspent, taking the mempool into account: if spent in the mempool it will *not* count as unspent.
