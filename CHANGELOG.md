# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.20.0
### Added
- Low version bounds for some dependencies.
- Compatibility with GHC 8.8.
- Faster retrieval of extended public key balances and transactions.

### Removed
- In-memory RocksDB-based cache.

### Changed
- Refactor codebase.

## 0.19.6
### Added
- Use a parallel strategy to compute key derivations.

### Fixed
- Do not fail health check upon transaction timeout while syncing.

### Changed
- Do not use conduits for xpub balance streams.
- Multiple minor refactorings.

## 0.19.5
### Changed
- Minor refactor to block import code.

### Fixed
- Minor fix to transaction timeout check.

## 0.19.4
### Fixed
- Clarify and correct health check algorithm.

## 0.19.3
### Changed
- Add address transactions to cache.
- Improve multi-address transaction retrieval algorithms.

## 0.19.2
### Removed
- Cache-Control header turned out to be unnecessary.

### Fixed
- Fix some minor errors in web module.

## 0.19.1
### Added
- Set Cache-Control header to no-cache.

## 0.19.0
### Changed
- Store mempool in single key/value pair.

## 0.18.11
### Changed
- Do not stream mempool.

## 0.18.10
### Removed
- Disable timeout checks for testnets.

## 0.18.9
### Added
- Endpoint to locate a block by unix timestamp.

### Removed
- No more persistence for peers due to dependency on newest haskoin-node.

## 0.18.8
### Added
- Transaction and block timeouts for health check.
- Raw blocks.

## 0.18.7
### Fixed
- Missing tranasctions on xpub listings.

## 0.18.6
### Removed
- Follow Stack advise removing `-O2` GHC option.

## 0.18.5
### Added
- Compatibility with SegWit on extended public key endpoints.

### Changed
- Fix syncing peer not reset after timeout.
- Use simpler monad for streaming data.

## 0.18.4
### Changed
- Bump Haskoin Node to fix peers not stored and excessively verbose logging.

## 0.18.3
### Changed
- Configurable HTTP request logging. Disabled by default.

## 0.18.2
### Changed
- Fix for memory leak.

## 0.18.1
### Removed
- Remove transaction count from xpub summary object.

## 0.18.0
### Changed
- Simplified limits and start point handling on web API.
- Made transaction streaming algorithm faster for xpub transactions.
- Extended public key summary output contains all addresses that have received transactions.

### Added
- Fine-grained control for maximum limits via command line options.
- Transaction hash as starting point.
- Block hash as starting point.
- Timestamp as starting point.
- Configurable xpub gap limit.
- Transaction count added to xpub summary.
- UTXO count added to xpub summary.

### Removed
- Mempool endpoint now has no limits or offsets and always returns full list.
- Extended public key summary output no longer includes any transactions.
- Offsets not allowed for transaction lists involving multiple addresses or xpubs.
- Confusing block position parameter no longer part of web API.

## 0.17.2
### Changed
- Stream address balances and unspent outputs.
- Add configurable max value for limit and offset which defaults at 10000.

## 0.17.1
### Changed
- When posting a transaction to the network, timeout is now five seconds.
- Improve error message when transaction post timeout reached.
- Remove obsolete `not found` error for transaction post.
- Endpoints for retrieving blocks now do streaming for better performance.
- Improve Swagger API documentation.

## 0.17.0
### Added
- Endpoints for retrieving block transactions.
- Endpoint for retrieving set of latest blocks.

### Changed
- Use standardized JSON and binary serialization schemes for raw transaction endpoints.

## 0.16.6
### Changed
- Now logging info messages too by default.
- Consolidated web logging in middleware.

### Removed
- UUIDs for web requests.

## 0.16.5
### Removed
- Remove concurrency from xpub balance requests to prevent RocksDB segfaults.

## 0.16.4
### Removed
- Remove concurrency from requests using iterators to prevent RocksDB from segfaulting.

## 0.16.3
### Added
- Debugging information for web API.

## 0.16.2
### Changed
- Debugging disabled by default (use `--debug` to enable).

## 0.16.1
### Added
- Cache mempool transactions.
- Improve initial syncing performance.

## 0.16.0
### Added
- Orphan transaction support.
- Full address balance cache in RocksDB.
- Full unspent output cache in RocksDB.

### Changed
- Significantly refactor code.
- Move web stuff to its own module.
- Change types related to databases.
- Make xpub balance, transaction and unspent queries fetch data in parallel.

## 0.15.2
### Added
- Internal data types to support orphan transactions.

### Changed
- Do not spam block actor with pings.
- Fix balance/unspent cache not reverting when importing fails.
- Fix transaction sorting algorithm not including transaction position information.
- Fix conflicting mempool transaction preventing block from importing.

## 0.15.1
### Changed
- Fix duplicate coinbase transaction id bug.

## 0.15.0
### Removed
- Removed `PreciseUnixTime` data type.

### Changed
- Use 64 bits for Unix time representation.
- Data model now uses simplified Unix time representation.

## 0.14.9
### Added
- Last external/change index information to xpub summary object.

## 0.14.8
### Added
- Endpoint for xpub summaries.
- Endpoints for full transactions.
- Ability to query by offset/limit.
- More API documentation.

## 0.14.7
### Added
- Debug information for `publishTx`.

### Changed
- Transaction publishing no longer requests mempool.
- Fixed serialization for `TxId` freezing the entire program by infinitely recursing.

## 0.14.6
### Changed
- Enable full threading again as it was deemed not responsible for the freezing behaviour.

## 0.14.5
### Changed
- Enable threading but leave it at a single thread to be able to open more than 1024 files.

## 0.14.4
### Changed
- Target LTS Haskell 13.20 and disable threading in new attempt to fix freezing bug.

## 0.14.3
### Changed
- Remove `-O2`.

## 0.14.2
### Changed
- Target LTS Haskell 12.26 to attempt to fix freezing bug.

## 0.14.1
### Added
- Extra debugging around code that freezes.

### Changed
- Bump dependency on `haskoin-node`.

## 0.14.0
### Removed
- Dump slow protobuf serialization.

### Added
- Add custom serialization.
- Extra debug logging.

### Changed
- Bump `haskoin-core` and `haskoin-node`.

## 0.13.1
### Changed
- Bump `haskoin-node` in `stack.yaml`.
- Do not send empty `getdata` messages.

## 0.13.0
### Added
- Primitive content negotiation for web exceptions.
- Protobuf support for errors.
- Protobuf support for tranasction ids.

### Changed
- Protobuf format changed in non-backwards-compatible manner for transaction ids.

## 0.12.0
### Added
- Support for binary serialization using Protocol Buffers.
- New endpoints for binary raw transactions (not hex-encoded).

### Changed
- Services field now a hex string instead of a number to avoid overflowing signed 64-bit integer.
- Flatten list of block data objects when responding to request for multiple block heights.
- Errors now reported in plain text without container JSON object.
- Transaction broadcasts are responded to with transaction id in plaintext hex (no JSON).
- Remove database snapshots to improve performance.

## 0.11.2
### Changed
- Fix duplicate mempool transaction announcements in event stream.

## 0.11.1
### Removed
- Removed latest block time check.

## 0.11.0
### Changed
- Improve post transactions endpoint.

## 0.10.1
### Changed
- Fix bug where transaction lists from multiple addresses would sort incorrectly.
- Address gap reduced to 20.

## 0.10.0
### Removed
- Remove addresses from transaction lists.
- No longer use container objects for xpub transactions.

## 0.9.3
### Added
- Permissive CORS headers to allow queries from any domain.
- Improved documentation using real-world examples from the BCH testnet.

## 0.9.2
### Added
- HTTP JSON API switch to turn off transaction list when retrieving blocks.

## 0.9.1
### Added
- Total block fees.
- Total block outputs.
- Block subsidy.

### Changed
- Do not consider the blocks less one block away from headers as out of sync in health check.
- Health check now returns HTTP 503 when not OK or out of sync.

## 0.9.0
### Added
- Version to health check output.
- Block weight for segwit.
- Transaction weight for segwit.

## 0.8.1
### Added
- Health check endpoint.

## 0.8.0
### Added
- Limits and skips.
- Add timestamps to transactions.
- Add transaction count to address balance object.
- Add Merkle root to block data.
- Total funds received by an address now shows up in balance.
- Balances for any address that ever had funds show up in xpub endpoints.

### Changed
- Data model update.
- Performance improvement for xpub calls.
- Transactions are returned in reverse mempool/block order (highest or most recent first).
- Balance objects do not get deleted from database ever.

## 0.6.9
### Changed
- Reduce number of coinbase checks to 10,000 ancestors.

## 0.6.8
### Changed
- Further optimize coinbase after height checks.

## 0.6.7
### Changed
- Impose restrictions on recursion for coinbase after height checks.

## 0.6.6
### Added
- Check whether a transaction can be traced back to a coinbase after certain height.

## 0.6.5
### Changed
- Delete transactions in reverse topological order when reverting a block.

## 0.6.4
### Changed
- Do not fail silently when importing orphan transactions into the mempool.

## 0.6.3
### Changed
- Dummy release to bump haskoin-node in stack.yaml.

## 0.6.2
### Changed
- Correct bug where coinbase transactions weren't properly flagged.

## 0.6.1
### Changed
- Compatibility with Bitcoin Cash hard fork.
- Various bug fixes.

## 0.6.0
### Added
- Address balance cache in memory.

### Changed
- Simplify data model further.
- Fix bug importing outputs with UTXO cache.
- Unspent balances cannot be negative.

## 0.5.0
### Added
- Add UTXO cache in memory.
- Get transactions with witness data in segwit networks.

### Changed
- Paths for derivations in xpubs is a list and no longer a string.
- Various bug fixes.

## 0.4.2
### Removed
- Remove extended public key itself from output of relevant endpoints to save bandwidth.

## 0.4.1
### Changed
- Fix bug when deleting coinbase transactions.
- Extended public key API support.

## 0.4.0
### Changed
- Generate events for mempool transactions.
- Respond with entire block data when querying blocks by height.

## 0.3.1
### Changed
- Do not import transactions to mempool while not synced.
- Only sync mempool against a single peer.
- Allow duplicate transactions to fix re-introduced sync bug.

## 0.3.0
### Added
- Update dependencies.
- Keep orphan blocks and deleted transactions in database.
- Add a `mainchain` field for block data and a `deleted` field for transactions.
- Stream records for performance.
- Show witness data for transaction inputs in SegWit network.
- Support RBF in SegWit network.

### Changed
- Refactor all data access code away from actor.
- Refactor import logic away from actor.
- Abstract data access using typeclasses.
- Implement data access using clean layered architecture.
- Make most of import logic code pure.
- Database now in `db` as opposed to `blocks` directory.
- Use latest `haskoin-node`.

### Removed
- Remove some data from peer information output.
- Remove full transaction from address transaction data.
- Remove limits from address transaction data.
- Remove block data from previous output.
- Remove spender from JSON response when output not spent.
- Remove block hash from block reference.

## 0.2.3
### Removed
- Do not send transaction notifications if a block is being imported.

## 0.2.2
### Added
- Peer information endpoint.

### Changed
- Update `haskoin-node`.

## 0.2.1
### Changed
- Fix tests

## 0.2.0
### Added
- Documentation everywhere.
- Ability to retrieve address transactions.

### Changed
- New versions of NQE and Haskoin Node upstream.
- Improve and simplify API.
- Multi-element endpoints return arrays of arrays.
- Database snapshots for all queries are now mandatory.

### Removed
- Retrieving unspent and spent outputs for an address.
- Redundant API endpoints for multiple elements.

## 0.1.3
### Changed
- Fix a bug with transaction notifications.
- Improve handling orphan transactions.

## 0.1.2
### Changed
- Specify dependencies better.

## 0.1.1
### Changed
- Dependency `secp256k1` is now `secp256k1-haskell`.

## 0.1.0
### Added
- New `CHANGELOG.md` file.
- Bitcoin (BTC) and Bitcoin Cash (BCH) compatibility.
- RocksDB database.
- Mempool support.
- HTTP streaming for events.
- CashAddr support.
- Bech32 support.
- Rate limits.

### Changed
- Split out of former `haskoin` repository.
- Use hpack and `package.yaml`.

### Removed
- Removed Stylish Haskell configuration file.
- Remvoed `haskoin-core` and `haskoin-wallet` packages from this repository.
