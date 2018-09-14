# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## 0.1.0
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
