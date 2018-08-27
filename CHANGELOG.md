# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- New `CHANGELOG.md` file.
- Support for Bitcoin (BTC) and Bitcoin Cash (BCH) networks.
- RocksDB database.
- Can index blocks and transactions in the blockchain.
- Mempool support.
- Supports HTTP streaming for events.
- Support for CashAddr addresses.
- Support for SegWit addresses.

### Changed
- Split out of former `haskoin` repository.
- Use hpack and `package.yaml`.

### Removed
- Removed Stylish Haskell configuration file.
- Remvoed `haskoin-core` and `haskoin-wallet` packages from this repository.
