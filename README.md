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

* [Swagger API Documentation](https://app.swaggerhub.com/apis/haskoin/haskoin-store/docs/0.1.0).


## Addresses & Balances

For every address Haskoin Store has a balance object that contains basic statistics about the address. These statistics are described below.

* `confirmed` balance is that which is in the blockchain. Will always be positive or zero.
* `unconfirmed` balance represent aggregate changes done by mempool transactions. Can be negative if the transactions currently in the mempool are expected to reduce the balance when all of them make it into the blockchain.
* `outputs` is the count of outputs that send funds to this address. It is just a count and not a monetary value.
* `utxo` is the count of outputs that send funds to this address that remain unspent, taking the mempool into account: if spent in the mempool it will *not* count as unspent.

## Limits

Various endpoints in the API will have both server and per-query limits to avoid overloading the server. Depending on the type of query being done the limits have varying effects.

### Multiple Objects in URI

If specifying multiple objects in the URI, for example when obtaining the balances for multiple addresses, no more than 500 elements may be requested.

If each object specified in the URI might lead to multiple results, these will be concatenated in the response, such that the first set of elements will correspond to the first requested item that yields any results, and the last set of elements will correspond to the last requested item that yields results, assuming that the number of returned items has not exceeded the count limit.

### Count Limit

The count limit is set by default at 10,000 server-wide. It may be changed via the server command line or for an individual request. The individual request limit may not be value larger than the server’s.

If the number of available results exceeds the count limit, and if stopping at exactly the limit would lead to a result set that would be partial for a block in the blockchain, any extra items that belong to the same block as the last element that fits within the limit will be appended to the results, exceeding the count limit.

When multiple objects are present in the URI and the result set exceeds the count limit, and stopping at the limit would lead to a partial result set for a requested item and block in the blockchain, any extra elements that pertain to the same item and block as the last element that fits within the limit will be appended.

The mempool is considered as a single block for count limit calculation purposes.

In short, a block worth of relevant data—or the mempool—will always be delivered in its entirety, regardless of the count limit.

### Height Limit

When delivering multiple results, Haskoin Store will start with data from the mempool, and then data from the highest block in the chain, followed by its parent, and so on until reaching the genesis block, or the count limit. Results are returned in reversed order from highest (latest) to lowest (earliest).

If the result set count matches or exceeds the count limit, it is possible that there are more entries available below the block height of the last result returned. By specifying a height limit in the query, the result set will start at the specified height, skipping any blocks above it.

Since block data is never delivered incomplete, it suffices to subtract one to the block height of the last returned element when performing the next request. If the last returned element is not in a block, then the height of the best block should be used for the next request.
