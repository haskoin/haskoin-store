#!/bin/sh

rm -rf src/Network/Haskoin/Store/ProtocolBuffers src/Network/Haskoin/Store/ProtocolBuffers.hs
hprotoc --proto_path=proto --prefix=Network.Haskoin.Store --haskell_out=src protocol-buffers.proto
