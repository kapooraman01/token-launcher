import { PrismaClient } from '../src/generated/prisma/client';
import { createTestPrisma, resetDatabase } from './utils/test-db';

const MAX_UINT256 = (2n ** 256n - 1n).toString();

describe('Database schema', () => {
  let prisma: PrismaClient;

  beforeAll(() => {
    prisma = createTestPrisma();
  });

  afterAll(async () => {
    await prisma.$disconnect();
  });

  beforeEach(async () => {
    await resetDatabase(prisma);
  });

  function coin(address: string) {
    return {
      address,
      curveAddress: `${address}c`,
      creator: '0xcreator',
      name: 'Test Coin',
      symbol: 'TEST',
      targetRaise: MAX_UINT256,
      initialVirtualEth: '1411675702937838861',
      platformFeeBps: 95,
      creatorFeeBps: 30,
      antiSnipeFeeBps: 5000,
      antiSnipeDuration: 30,
      virtualEthReserve: MAX_UINT256,
      virtualTokenReserve: '1073000000000000000000000000',
      createdBlock: 2n ** 62n,
      createdTxHash: '0xtx',
      createdAt: new Date(),
    };
  }

  function trade(coinAddress: string, txHash: string, logIndex: number) {
    return {
      coinAddress,
      side: 'BUY' as const,
      trader: '0xtrader',
      ethAmount: MAX_UINT256,
      tokenAmount: '1',
      platformFee: '0',
      creatorFee: '0',
      virtualEthReserve: '1',
      virtualTokenReserve: '1',
      blockNumber: 1n,
      blockHash: '0xblock',
      txHash,
      logIndex,
      timestamp: new Date(),
    };
  }

  it('stores full uint256 values and 64-bit block numbers exactly', async () => {
    await prisma.coin.create({ data: coin('0xa') });

    const stored = await prisma.coin.findUniqueOrThrow({
      where: { address: '0xa' },
    });
    expect(stored.targetRaise.toFixed()).toBe(MAX_UINT256);
    expect(stored.virtualEthReserve.toFixed()).toBe(MAX_UINT256);
    expect(BigInt(stored.virtualTokenReserve.toFixed())).toBe(
      1_073_000_000n * 10n ** 18n,
    );
    expect(stored.createdBlock).toBe(2n ** 62n);
  });

  it('rejects the same event being stored twice', async () => {
    await prisma.coin.create({ data: coin('0xa') });
    await prisma.trade.create({ data: trade('0xa', '0xtx1', 3) });

    await expect(
      prisma.trade.create({ data: trade('0xa', '0xtx1', 3) }),
    ).rejects.toThrow();
    await expect(
      prisma.trade.create({ data: trade('0xa', '0xtx1', 4) }),
    ).resolves.toBeDefined();
  });

  it('silently rounds fractional input, so callers must pass integer strings', async () => {
    await prisma.coin.create({ data: coin('0xa') });
    const stored = await prisma.trade.create({
      data: { ...trade('0xa', '0xtx1', 0), tokenAmount: '1.6' },
    });
    expect(stored.tokenAmount.toFixed()).toBe('2');
  });

  it('deletes trades when their coin is deleted', async () => {
    await prisma.coin.create({ data: coin('0xa') });
    await prisma.trade.create({ data: trade('0xa', '0xtx1', 0) });

    await prisma.coin.delete({ where: { address: '0xa' } });

    expect(await prisma.trade.count()).toBe(0);
  });
});
