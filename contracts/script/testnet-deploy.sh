#!/usr/bin/env bash
# Deploys to Robinhood Chain testnet (46630) and verifies the source on Blockscout.
#
#   ACCOUNT=<foundry keystore name> OWNER=<owner address> ./script/testnet-deploy.sh
#
# ACCOUNT is a key imported with `cast wallet import <name> --interactive`; its password is asked
# for at signing time, so no private key is ever written to disk or shell history. Other settings
# (TARGET_RAISE_WEI, fees, caps) can be overridden through the environment; see .env.example.
set -euo pipefail

: "${ACCOUNT:?set ACCOUNT to a foundry keystore name}"
: "${OWNER:?set OWNER to the owner address}"

cd "$(dirname "$0")/.."

forge script script/Deploy.s.sol \
  --rpc-url robinhood_testnet \
  --account "$ACCOUNT" \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.chain.robinhood.com/api/

RUN=broadcast/Deploy.s.sol/46630/run-latest.json
FACTORY=$(jq -r '.transactions[] | select(.contractName=="LaunchFactory") | .contractAddress' "$RUN")
START_BLOCK=$(jq -r '.receipts[0].blockNumber' "$RUN" | cast to-dec)

echo
echo "Add to apps/api/.env:"
echo "CHAIN_ID=46630"
echo "RPC_URL=https://rpc.testnet.chain.robinhood.com"
echo "FACTORY_ADDRESS=$(cast to-check-sum-address "$FACTORY")"
echo "START_BLOCK=$START_BLOCK"
echo
echo "Explorer: https://explorer.testnet.chain.robinhood.com/address/$FACTORY"
