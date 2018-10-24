# Haskoin Store

Full blockchain index & store featuring:

- Bitcoin Cash & Bitcoin SegWit support.
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
