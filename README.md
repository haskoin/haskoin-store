# Haskoin

[![Build Status](https://travis-ci.org/haskoin/haskoin.svg?branch=master)](https://travis-ci.org/haskoin/haskoin)

Haskoin is an implementation of the Bitcoin protocol in Haskell. There are currently three packages in the Haskoin main repository.

Supported networks:

- Bitcoin
- Bitcoin Cash
- Testnet3
- Bitcoin Cash Testnet
- RegTest

## Packages

### haskoin-core

Pure code related to the Bitcoin protocol.

- Hashing functions
- Block header validation
- Base58 addresses
- BIP32 extended key derivation and parsing (m/1'/2/3)
- BIP39 mnemonic keys
- ECDSA cryptographic primitives (using external libsecp256k1 library)
- Building and signing standard transactions (regular, multisig, p2sh)
- Script parsing and evaluation (experimental)
- Bitcoin protocol messages
- Bloom filters and partial merkle tree manipulations for SPV wallets
- Comprehensive test suite

### haskoin-node

Network Server Node Library supporting:

- Peer Discovery & Management
- Headers-first synchronisation
- Regular and Merkle block download
- Transaction download & upload
- Persistent storage for headers and peers using RocksDB
- Hooks for other features

### haskoin-store

Full blockchain index & store supporting:

- Address index
- Persistent storage using RocksDB
- UTXO cache for faster indexing
- RESTful endpoints for blockchain data

[API Documentation and example server](https://app.swaggerhub.com/apis/haskoin/blockchain-api/0.0.1-oas3)

## Installation Instructions

To install `haskoin-store`:

- Get [Stack](https://haskell-lang.org/get-started)
- Get [RocksDB](http://rocksdb.org/)
- Clone this repository `git clone https://github.com/xenog/haskoin`
- From the root of the repository run `stack install`

You may need to get additional libraries if installation fails.
