import { Wallet } from 'ethers';
import { PrismaClient } from '../src/generated/prisma/client';
import { IndexerStore } from '../src/indexer/indexer.store';
import {
  AnvilChain,
  deployLaunch,
  ROBINHOOD_TESTNET_RPC,
  startAnvil,
} from './utils/anvil';
import { LaunchHarness } from './utils/launch-harness';
import { createTestPrisma, resetDatabase } from './utils/test-db';

/**
 * Graduation needs Uniswap v4, so this suite runs on an Anvil fork of Robinhood Chain testnet
 * (network access required; set ROBINHOOD_TESTNET_RPC to use another endpoint).
 */
describe('Graduation indexing (e2e against a testnet fork)', () => {
  let chain: AnvilChain;
  let prisma: PrismaClient;
  let h: LaunchHarness;
  let alice: Wallet;
  let bob: Wallet;

  beforeAll(async () => {
    chain = await startAnvil(8548, ROBINHOOD_TESTNET_RPC);
    prisma = createTestPrisma();
    const [deployer] = chain.wallets;
    [, alice, bob] = chain.wallets;
    h = new LaunchHarness(chain, await deployLaunch(deployer), prisma);
  });

  afterAll(async () => {
    await prisma?.$disconnect();
    await chain?.stop();
  });

  beforeEach(async () => {
    await resetDatabase(prisma);
    h.startBlock = (await chain.provider.getBlockNumber()) + 1;
  });

  afterEach(async () => {
    await h.closeIndexers();
  });

  async function launchAndGraduate() {
    const coin = await h.launch(alice);
    await chain.provider.send('evm_increaseTime', [60]);
    await h.buy(coin.curve, bob, '20');
    const receipt = await h.send(coin.curve, alice, 'graduate');
    return { coin, receipt };
  }

  it('records graduation with the Uniswap pool id and the liquidity added', async () => {
    const { coin, receipt } = await launchAndGraduate();
    await h.syncAll((await h.createIndexer()).indexer);

    const stored = await prisma.coin.findUniqueOrThrow({
      where: { address: coin.token },
    });
    const expectedPoolId = (await h.contracts.locker.getFunction('poolId')(
      coin.token,
    )) as string;
    const graduated = receipt.logs
      .map((log) => {
        try {
          return h.contracts.locker.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((parsed) => parsed?.name === 'Graduated');

    expect(stored.completed).toBe(true);
    expect(stored.graduated).toBe(true);
    expect(stored.graduatedBlock).toBe(BigInt(receipt.blockNumber));
    expect(stored.poolId).toBe(expectedPoolId);
    expect(stored.poolEth?.toFixed()).toBe(
      (graduated!.args.ethAdded as bigint).toString(),
    );
    expect(stored.poolTokens?.toFixed()).toBe(
      (graduated!.args.tokensAdded as bigint).toString(),
    );
    await h.expectDatabaseMatchesChain();
  });

  it('undoes a graduation that a reorg removes', async () => {
    const coin = await h.launch(alice);
    await chain.provider.send('evm_increaseTime', [60]);
    await h.buy(coin.curve, bob, '20');
    const { indexer, module } = await h.createIndexer();
    const rewind = jest.spyOn(module.get(IndexerStore), 'rewind');
    await h.syncAll(indexer);

    const snapshot = (await chain.provider.send('evm_snapshot', [])) as string;
    await h.send(coin.curve, alice, 'graduate');
    await h.syncAll(indexer);
    expect(
      (await prisma.coin.findUniqueOrThrow({ where: { address: coin.token } }))
        .graduated,
    ).toBe(true);

    await chain.provider.send('evm_revert', [snapshot]);
    await chain.provider.send('anvil_mine', ['0x3']);
    await h.syncAll(indexer);

    expect(rewind).toHaveBeenCalledTimes(1);
    const stored = await prisma.coin.findUniqueOrThrow({
      where: { address: coin.token },
    });
    expect(stored.completed).toBe(true);
    expect(stored.graduated).toBe(false);
    expect(stored.poolId).toBeNull();
    await h.expectDatabaseMatchesChain();
  });
});
