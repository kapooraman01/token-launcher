import { parseEther, Wallet } from 'ethers';
import { PrismaClient } from '../src/generated/prisma/client';
import { IndexerStore, StaleCursorError } from '../src/indexer/indexer.store';
import { AnvilChain, deploy, deployLaunch, startAnvil } from './utils/anvil';
import { LaunchHarness } from './utils/launch-harness';
import { createTestPrisma, resetDatabase } from './utils/test-db';

describe('Indexer (e2e against Anvil)', () => {
  let chain: AnvilChain;
  let prisma: PrismaClient;
  let h: LaunchHarness;
  let alice: Wallet;
  let bob: Wallet;

  beforeAll(async () => {
    chain = await startAnvil(8547);
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
    // Tests share one chain; each indexes only the blocks it creates.
    h.startBlock = (await chain.provider.getBlockNumber()) + 1;
  });

  afterEach(async () => {
    await h.closeIndexers();
  });

  async function createIndexer() {
    return (await h.createIndexer()).indexer;
  }

  it('indexes launches, trades and completion exactly as they are on chain', async () => {
    const first = await h.launch(alice, parseEther('0.01'));
    await chain.provider.send('evm_increaseTime', [60]);
    await h.buy(first.curve, bob, '0.5');
    await h.buy(first.curve, alice, '0.2');
    await h.sellHalf(first, bob);

    const second = await h.launch(bob);
    await chain.provider.send('evm_increaseTime', [60]);
    await h.buy(second.curve, alice, '10');

    await h.syncAll(await createIndexer());

    expect(await prisma.coin.count()).toBe(2);
    expect(await prisma.trade.count()).toBe(5);
    const completed = await prisma.coin.findUniqueOrThrow({
      where: { address: second.token },
    });
    expect(completed.completed).toBe(true);
    expect(completed.graduated).toBe(false);
    const creatorBuy = await prisma.trade.findFirstOrThrow({
      where: { coinAddress: first.token },
      orderBy: { id: 'asc' },
    });
    expect(creatorBuy.trader).toBe(alice.address);
    await h.expectDatabaseMatchesChain();
  });

  it('ignores contracts that imitate our events', async () => {
    const impostor = await deploy('ImpostorCurve', alice);
    await h.send(impostor, alice, 'fakeLaunch');
    await h.send(impostor, alice, 'fakeBuy');
    const real = await h.launch(alice);
    await h.buy(real.curve, bob, '0.1');

    await h.syncAll(await createIndexer());

    expect(await prisma.coin.count()).toBe(1);
    expect(await prisma.trade.count()).toBe(1);
    await h.expectDatabaseMatchesChain();
  });

  it('resumes from its cursor after a restart without duplicating trades', async () => {
    const coin = await h.launch(alice);
    await h.buy(coin.curve, bob, '0.1');
    await h.syncAll(await createIndexer());

    await h.buy(coin.curve, alice, '0.1');
    await h.buy(coin.curve, bob, '0.1');
    await h.syncAll(await createIndexer());

    expect(await prisma.trade.count()).toBe(3);
    await h.expectDatabaseMatchesChain();
  });

  it('lets only one of two concurrent indexers write the same range', async () => {
    const coin = await h.launch(alice);
    await h.buy(coin.curve, bob, '0.1');
    const [first, second] = [await createIndexer(), await createIndexer()];

    const results = await Promise.allSettled([first.tick(), second.tick()]);

    const rejected = results.filter(
      (result): result is PromiseRejectedResult => result.status === 'rejected',
    );
    expect(rejected).toHaveLength(1);
    expect(rejected[0].reason).toBeInstanceOf(StaleCursorError);
    await h.syncAll(first);
    expect(await prisma.coin.count()).toBe(1);
    expect(await prisma.trade.count()).toBe(1);
    await h.expectDatabaseMatchesChain();
  });

  it('rewinds and reindexes when blocks it already indexed are replaced', async () => {
    const coin = await h.launch(alice);
    const { indexer, module } = await h.createIndexer();
    const rewind = jest.spyOn(module.get(IndexerStore), 'rewind');
    await h.syncAll(indexer);

    const forkBlock = await chain.provider.getBlockNumber();
    const snapshot = (await chain.provider.send('evm_snapshot', [])) as string;
    await h.buy(coin.curve, bob, '1');
    await h.syncAll(indexer);
    expect(await prisma.trade.count()).toBe(1);
    expect(rewind).not.toHaveBeenCalled();

    await chain.provider.send('evm_revert', [snapshot]);
    await h.buy(coin.curve, alice, '0.2');
    await chain.provider.send('anvil_mine', ['0x2']);
    await h.syncAll(indexer);

    expect(rewind).toHaveBeenCalledTimes(1);
    expect(rewind.mock.calls[0][1]?.blockNumber).toBe(forkBlock);
    const trades = await prisma.trade.findMany();
    expect(trades).toHaveLength(1);
    expect(trades[0].trader).toBe(alice.address);
    await h.expectDatabaseMatchesChain();
  });
});
