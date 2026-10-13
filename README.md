# Token Launcher (Robinhood Chain)

A pump.fun-style launcher: anyone can launch a coin whose entire fixed supply sits in an immutable
bonding curve, and anyone can buy and sell against that curve with ETH. When a curve sells out, the
coin graduates into a Uniswap v4 pool whose liquidity is locked forever, and swap fees on that pool
are split between the creator and the platform. Module 1 built the curve and the indexing backend;
Module 2 added graduation. Nothing is deployed to mainnet yet.

## Layout

- `contracts/` - Foundry project: `LaunchToken`, `BondingCurve`, `LaunchFactory`, `FeeVault`,
  `GraduationLocker`. See [contracts/README.md](contracts/README.md).
- `apps/api/` - NestJS backend: indexer (chain events into Postgres) and the read-only REST API.
- `packages/shared/` - chain constants, curve math constants and contract ABIs used by every app.

## Prerequisites

- Node 22 (`nvm use`), pnpm 10
- Foundry (`foundryup`) and `jq`
- Docker (for Postgres)

## Local quickstart

```bash
pnpm install
docker compose up -d                          # Postgres on 127.0.0.1:5434

anvil                                         # in a separate terminal
contracts/script/local-deploy.sh              # prints FACTORY_ADDRESS and START_BLOCK

cp apps/api/.env.example apps/api/.env        # then paste the values printed above
pnpm api db:deploy
pnpm api build && pnpm api start:prod
curl localhost:3000/coins
```

## API

All responses are JSON. Amounts are decimal strings of raw uint256 values (wei or token base
units); never parse them as JavaScript numbers.

- `GET /coins?limit=&cursor=` - coins, newest launch first
- `GET /coins/:address` - one coin, including reserves, curve progress and, once graduated, its
  Uniswap v4 `poolId` and the ETH and tokens the pool was opened with
- `GET /coins/:address/trades?limit=&cursor=` - its trades, newest first

`limit` is 1-100 (default 20). Pass `nextCursor` from the previous page as `cursor`.

## Tests

```bash
pnpm contracts:test                           # unit, fuzz, invariant and fork tests
pnpm api test                                 # backend unit tests
pnpm api test:e2e                             # Postgres + Anvil end-to-end tests
```

The e2e tests need the Docker Postgres running and `anvil` on the PATH. They use a separate
`launcher_test` database. Graduation tests (`contracts/test/fork`, `apps/api/test/graduation`)
run against a fork of Robinhood Chain testnet so they use the real Uniswap v4 contracts; they
need network access. Set `ROBINHOOD_TESTNET_RPC` to use another endpoint.

## Testnet staging (Robinhood Chain testnet, 46630)

1. Import a deployer key once: `cast wallet import staging-deployer --interactive`, and fund it
   from `faucet.testnet.chain.robinhood.com`.
2. Deploy and verify. A low target raise lets a coin be completed and graduated with faucet ETH;
   the graduation fee must stay within 5% of the target raise:

   ```bash
   cd contracts
   ACCOUNT=staging-deployer OWNER=<owner address> \
     TARGET_RAISE_WEI=100000000000000000 \
     GRADUATION_FEE_WEI=2000000000000000 GRADUATION_REWARD_WEI=100000000000000 \
     ./script/testnet-deploy.sh
   ```

3. Put the printed values in `apps/api/.env` and start the API.
4. Launch coins and trade on the testnet, fill one curve and call `graduate()` on it, then swap
   on its Uniswap pool and call `collectFees` on the locker.
5. Check every coin against the chain: `API_URL=http://localhost:3000
   RPC_URL=https://rpc.testnet.chain.robinhood.com pnpm api verify:chain`

A gas-free check that runs the whole lifecycle (deploy, launch, trade, fill, graduate into the
real Uniswap v4, swap, collect and claim fees) on the real testnet EVM, with nothing broadcast:

```bash
cd contracts && forge build
cast call --rpc-url https://rpc.testnet.chain.robinhood.com \
  --from 0x000000000000000000000000000000000000bEEF --value 30ether --gas-limit 300000000 \
  --override-balance 0x000000000000000000000000000000000000bEEF:100000000000000000000 \
  --create $(jq -r '.bytecode.object' out/TestnetSmoke.sol/TestnetSmoke.json)
```

It prints the contract's runtime code on success and reverts if any step misbehaves.
