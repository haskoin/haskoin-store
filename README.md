# Haskoin

[![Build Status](https://travis-ci.org/haskoin/haskoin.svg?branch=master)](https://travis-ci.org/haskoin/haskoin)

Haskoin is an implementation of the Bitcoin protocol in Haskell. There are
currently 2 main packages in Haskoin, namely haskoin-core and haskoin-node.

## haskoin-core

haskoin-core is a package implementing the core functionalities of the Bitcoin
protocol specifications. The following features are provided:

- Hashing functions (sha-256, ripemd-160)
- Block validation
- Base58 encoding
- BIP32 extended key derivation and parsing (m/1'/2/3)
- BIP39 mnemonic keys
- ECDSA cryptographic primitives (using the C library libsecp256k1)
- Script parsing and evaluation
- Building and signing of standard transactions (regular, multisig, p2sh)
- Parsing and manipulation of all Bitcoin protocol types
- Bloom filters and partial merkle tree library (used in SPV wallets)
- Comprehensive test suite

A wallet implementation is available in haskoin-wallet which uses both this
package and the node implementation in haskoin-node.

[haskoin-core hackage documentation](http://hackage.haskell.org/package/haskoin-core)

## haskoin-node

haskoin-node is the network server node. It
implements the Bitcoin protocol in Haskell and allows the
synchronization of headers and the download of blocks and transactions. haskoin-node is
not a full node, but a node library, and provides:

- Implementation of the Bitcoin network protocol
- Header proof-of-work validation
- Headers-first synchronization
- Peer discovery and management
- Full block download
- Merkle block download
- Transaction download
- Hooks for extra features

[haskoin-node hackage documentation](http://hackage.haskell.org/package/haskoin-node)
