#!/usr/bin/env bash
# Anvil has no Arbitrum precompiles. The curve reads the L2 block number from ArbSys at
# address 0x64, so on a local chain we install MockArbSys there before deploying.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ARBSYS=0x0000000000000000000000000000000000000064

cd "$(dirname "$0")/.."
forge build --quiet
CODE=$(jq -r '.deployedBytecode.object' out/MockArbSys.sol/MockArbSys.json)
cast rpc --rpc-url "$RPC_URL" anvil_setCode "$ARBSYS" "$CODE" > /dev/null
echo "MockArbSys installed at $ARBSYS on $RPC_URL"
