#!/usr/bin/env bash
# Deploys the contracts to a running local Anvil node (start one with `anvil`) and prints the
# values apps/api/.env needs. Uses Anvil's first default key, which must never hold real funds.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
ANVIL_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

cd "$(dirname "$0")/.."
./script/local-arbsys.sh

OWNER=$(cast wallet address "$ANVIL_KEY") forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" --private-key "$ANVIL_KEY" --broadcast --silent

RUN=broadcast/Deploy.s.sol/31337/run-latest.json
FACTORY=$(jq -r '.transactions[] | select(.contractName=="LaunchFactory") | .contractAddress' "$RUN")
START_BLOCK=$(jq -r '.receipts[0].blockNumber' "$RUN" | cast to-dec)

echo "CHAIN_ID=31337"
echo "RPC_URL=$RPC_URL"
echo "FACTORY_ADDRESS=$(cast to-check-sum-address "$FACTORY")"
echo "START_BLOCK=$START_BLOCK"
