# Contracts

Solidity 0.8.30, OpenZeppelin 5.7, Uniswap v4-core 4.0.0 (MIT interfaces and maths only), EVM
version `cancun` (supported by Robinhood Chain's ArbOS).

## Contracts

- `LaunchToken` - plain ERC20. Exactly 1,000,000,000 tokens are minted once to the coin's curve.
  No owner, mint, burn, pause, blocklist or transfer fees.
- `BondingCurve` - one minimal-proxy clone per coin. Constant product (`x * y = k`) against virtual
  reserves: 793.1M tokens are sold on the curve, 206.9M are kept for the future DEX pool. When the
  last curve token is sold, the curve switches to `Complete` and all trading stops. Anyone may
  then call `graduate()`: the raised ETH minus the graduation fee, paired with exactly enough
  reserved tokens to open at the curve's final price, moves to the `GraduationLocker`; every other
  token is burned, and the caller earns a small reward.
- `LaunchFactory` - creates the token and curve, and runs the creator's optional capped first buy
  in the same transaction. Its owner can set fees for future coins within hard caps and pause new
  launches; it has no power over existing curves.
- `GraduationLocker` - deployed by the factory at a CREATE2 address that makes it a Uniswap v4
  hook with only the `beforeInitialize` permission, which lets nobody but itself create a pool.
  It creates each coin's ETH/token pool, adds the liquidity as one full-range position it owns,
  and has no code that removes liquidity. Anyone can call `collectFees`; the platform's share
  goes to the FeeVault and the creator's share is claimable with `claim`.
- `FeeVault` - receives platform fees in ETH and, after graduation, in coin tokens; only its
  owner can withdraw.
- `libraries/BondingCurveMath`, `libraries/PoolMath`, `libraries/LaunchLimits`,
  `libraries/ArbBlock` - curve formulas, pool price and liquidity maths, compile-time hard caps,
  and the L2 block number from the ArbSys precompile.

## Security properties

- Immutable: no proxies to upgrade, no admin over curves, no way to mint or move user funds.
- Reserves live in storage; tokens or ETH sent directly to a curve cannot change prices.
- Every rounding favours the curve, so the curve can always pay every holder who sells.
- Reentrancy guards (transient storage) and checks-effects-interactions on every external call.
- Creator fees are accrued and claimed, never pushed, so a creator cannot block trading.
- Every buy and sell has a minimum-output and a deadline. One buy per wallet per L2 block. A
  decaying anti-snipe fee applies for the first seconds after launch.
- A coin's Uniswap pool can only be created by the locker, at exactly the curve's final price, so
  it cannot be pre-created at a manipulated price. Its liquidity can never be withdrawn.

Static analysis findings and their triage: [docs/static-analysis.md](docs/static-analysis.md).

## Commands

```bash
forge build
forge test                        # unit, fuzz (10k runs), invariant and fork tests
forge test --no-match-path "test/fork/*"   # everything that runs offline
FOUNDRY_PROFILE=ci forge test     # deeper fuzzing
forge coverage --no-match-coverage "test|script" --ir-minimum
slither .
```

## Deploying

- Local Anvil: `anvil`, then `./script/local-deploy.sh`. Plain Anvil has no Uniswap, so
  graduation only works on a fork: `anvil --fork-url https://rpc.testnet.chain.robinhood.com`.
- Robinhood Chain testnet: `./script/testnet-deploy.sh` (see the root README).
- After changing a contract: `pnpm shared export-abis && pnpm shared build` so the backend uses the
  new ABIs.

On a local chain the ArbSys precompile does not exist; `script/local-arbsys.sh` installs
`MockArbSys` at its address.
