import { ConfigModule } from '@nestjs/config';
import { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { getAddress } from 'ethers';
import request from 'supertest';
import { App } from 'supertest/types';
import {
  CURVE_SUPPLY,
  INITIAL_VIRTUAL_TOKEN_RESERVE,
  initialVirtualEth,
} from '@token-launcher/shared';
import { ApiModule } from '../src/api.module';
import { configureApp } from '../src/app.setup';
import { validateEnv } from '../src/config/env.schema';
import { PrismaClient } from '../src/generated/prisma/client';
import { PrismaModule } from '../src/prisma/prisma.module';
import { PrismaService } from '../src/prisma/prisma.service';
import { createTestPrisma, resetDatabase } from './utils/test-db';

const TARGET_RAISE = 4n * 10n ** 18n;
const START_ETH = initialVirtualEth(TARGET_RAISE);
const ALLOWED_ORIGIN = 'https://app.example.com';

/** Checksummed, like every address the indexer stores. */
function address(n: number): string {
  return getAddress(`0x${n.toString(16).padStart(40, '0')}`);
}
const COIN_A = address(0xa1);
const COIN_B = address(0xa2);
const COIN_C = address(0xa3);

async function createApp(
  env: Record<string, string> = {},
): Promise<NestExpressApplication> {
  Object.assign(process.env, {
    CHAIN_ID: '31337',
    RPC_URL: 'http://127.0.0.1:8545',
    FACTORY_ADDRESS: address(0xf1),
    START_BLOCK: '0',
    CORS_ORIGINS: ALLOWED_ORIGIN,
    THROTTLE_LIMIT: '1000',
    ...env,
  });
  const module = await Test.createTestingModule({
    imports: [
      ConfigModule.forRoot({
        isGlobal: true,
        ignoreEnvFile: true,
        validate: validateEnv,
      }),
      PrismaModule,
      ApiModule,
    ],
  }).compile();
  const app = module.createNestApplication<NestExpressApplication>();
  configureApp(app);
  await app.init();
  return app;
}

describe('Coins API (e2e)', () => {
  let prisma: PrismaClient;
  let app: NestExpressApplication;
  let http: App;

  beforeAll(async () => {
    prisma = createTestPrisma();
    await resetDatabase(prisma);
    await seed(prisma);
    app = await createApp();
    http = app.getHttpServer();
  });

  afterAll(async () => {
    await app.close();
    await prisma.$disconnect();
  });

  async function seed(db: PrismaClient): Promise<void> {
    const sold = CURVE_SUPPLY / 4n;
    for (const [i, coin] of [COIN_A, COIN_B, COIN_C].entries()) {
      await db.coin.create({
        data: {
          address: coin,
          curveAddress: address(0xc0 + i),
          creator: address(0xe1),
          name: `Coin ${i}`,
          symbol: `C${i}`,
          targetRaise: TARGET_RAISE.toString(),
          initialVirtualEth: START_ETH.toString(),
          platformFeeBps: 95,
          creatorFeeBps: 30,
          antiSnipeFeeBps: 5000,
          antiSnipeDuration: 30,
          virtualEthReserve: (START_ETH + 10n ** 18n).toString(),
          virtualTokenReserve: (
            INITIAL_VIRTUAL_TOKEN_RESERVE - sold
          ).toString(),
          createdBlock: BigInt(100 + i),
          createdTxHash: `0xtx${i}`,
          createdAt: new Date(1_700_000_000_000 + i * 1000),
        },
      });
    }
    for (let i = 0; i < 5; i++) {
      await db.trade.create({
        data: {
          coinAddress: COIN_A,
          side: i % 2 === 0 ? 'BUY' : 'SELL',
          trader: address(0xb1),
          ethAmount: (10n ** 18n + BigInt(i)).toString(),
          tokenAmount: '123456789012345678901234567',
          platformFee: '1',
          creatorFee: '2',
          virtualEthReserve: '3',
          virtualTokenReserve: '4',
          blockNumber: BigInt(200 + i),
          blockHash: `0xblock${i}`,
          txHash: `0xtrade${i}`,
          logIndex: 0,
          timestamp: new Date(1_700_000_100_000 + i * 1000),
        },
      });
    }
  }

  describe('GET /coins', () => {
    it('lists coins newest first with exact amounts and curve progress', async () => {
      const res = await request(http).get('/coins').expect(200);
      const body = res.body as {
        items: Record<string, unknown>[];
        nextCursor: string | null;
      };

      expect(body.items.map((coin) => coin.address)).toEqual([
        COIN_C,
        COIN_B,
        COIN_A,
      ]);
      expect(body.nextCursor).toBeNull();
      expect(body.items[2]).toMatchObject({
        name: 'Coin 0',
        targetRaise: TARGET_RAISE.toString(),
        realEthReserve: (10n ** 18n).toString(),
        tokensSold: (CURVE_SUPPLY / 4n).toString(),
        progressBps: 2500,
        completed: false,
        createdBlock: '100',
      });
    });

    it('paginates with a cursor', async () => {
      const first = await request(http).get('/coins?limit=2').expect(200);
      const firstBody = first.body as {
        items: { address: string }[];
        nextCursor: string;
      };
      expect(firstBody.items.map((coin) => coin.address)).toEqual([
        COIN_C,
        COIN_B,
      ]);
      expect(firstBody.nextCursor).toBe(COIN_B);

      const second = await request(http)
        .get(`/coins?limit=2&cursor=${firstBody.nextCursor}`)
        .expect(200);
      const secondBody = second.body as {
        items: { address: string }[];
        nextCursor: string | null;
      };
      expect(secondBody.items.map((coin) => coin.address)).toEqual([COIN_A]);
      expect(secondBody.nextCursor).toBeNull();
    });

    it.each([
      'limit=0',
      'limit=101',
      'limit=abc',
      'cursor=0x1234',
      'unknown=1',
    ])('rejects ?%s', async (query) => {
      await request(http).get(`/coins?${query}`).expect(400);
    });
  });

  describe('GET /coins/:address', () => {
    it('returns one coin and accepts any address casing', async () => {
      const res = await request(http)
        .get(`/coins/${COIN_A.toLowerCase()}`)
        .expect(200);
      expect((res.body as { address: string }).address).toBe(COIN_A);
    });

    it('reports graduation status and the Uniswap pool', async () => {
      const before = await request(http).get(`/coins/${COIN_B}`).expect(200);
      expect(before.body).toMatchObject({
        graduated: false,
        graduatedBlock: null,
        poolId: null,
        poolEth: null,
        poolTokens: null,
      });

      const poolId = `0x${'ab'.repeat(32)}`;
      await prisma.coin.update({
        where: { address: COIN_B },
        data: {
          completed: true,
          graduated: true,
          graduatedBlock: 500n,
          poolId,
          poolEth: '3980000000000000000',
          poolTokens: '201000000000000000000000000',
        },
      });

      const after = await request(http).get(`/coins/${COIN_B}`).expect(200);
      expect(after.body).toMatchObject({
        completed: true,
        graduated: true,
        graduatedBlock: '500',
        poolId,
        poolEth: '3980000000000000000',
        poolTokens: '201000000000000000000000000',
      });
    });

    it('rejects an invalid address', async () => {
      await request(http).get('/coins/not-an-address').expect(400);
    });

    it('returns 404 for an unknown coin', async () => {
      await request(http)
        .get(`/coins/${address(0xdead)}`)
        .expect(404);
    });
  });

  describe('GET /coins/:address/trades', () => {
    it('lists trades newest first and paginates', async () => {
      const first = await request(http)
        .get(`/coins/${COIN_A}/trades?limit=3`)
        .expect(200);
      const firstBody = first.body as {
        items: {
          blockNumber: string;
          ethAmount: string;
          tokenAmount: string;
        }[];
        nextCursor: string;
      };
      expect(firstBody.items.map((trade) => trade.blockNumber)).toEqual([
        '204',
        '203',
        '202',
      ]);
      expect(firstBody.items[0].ethAmount).toBe((10n ** 18n + 4n).toString());
      expect(firstBody.items[0].tokenAmount).toBe(
        '123456789012345678901234567',
      );

      const second = await request(http)
        .get(`/coins/${COIN_A}/trades?limit=3&cursor=${firstBody.nextCursor}`)
        .expect(200);
      const secondBody = second.body as {
        items: { blockNumber: string }[];
        nextCursor: string | null;
      };
      expect(secondBody.items.map((trade) => trade.blockNumber)).toEqual([
        '201',
        '200',
      ]);
      expect(secondBody.nextCursor).toBeNull();
    });

    it('returns an empty page for a coin without trades', async () => {
      const res = await request(http)
        .get(`/coins/${COIN_B}/trades`)
        .expect(200);
      expect(res.body).toEqual({ items: [], nextCursor: null });
    });

    it.each(['cursor=abc', 'cursor=0', 'cursor=9999999999999999999'])(
      'rejects ?%s',
      async (query) => {
        await request(http).get(`/coins/${COIN_A}/trades?${query}`).expect(400);
      },
    );

    it('returns 404 for an unknown coin', async () => {
      await request(http)
        .get(`/coins/${address(0xdead)}/trades`)
        .expect(404);
    });
  });

  describe('hardening', () => {
    it('sends security headers and hides the framework', async () => {
      const res = await request(http).get('/coins').expect(200);
      expect(res.headers['x-content-type-options']).toBe('nosniff');
      expect(res.headers['content-security-policy']).toBeDefined();
      expect(res.headers['x-powered-by']).toBeUndefined();
    });

    it('allows only configured origins', async () => {
      const allowed = await request(http)
        .get('/coins')
        .set('Origin', ALLOWED_ORIGIN);
      expect(allowed.headers['access-control-allow-origin']).toBe(
        ALLOWED_ORIGIN,
      );

      const denied = await request(http)
        .get('/coins')
        .set('Origin', 'https://evil.example.com');
      expect(denied.headers['access-control-allow-origin']).toBeUndefined();
    });

    it('hides internal error details from clients', async () => {
      const prismaService = app.get(PrismaService);
      jest
        .spyOn(prismaService.coin, 'findMany')
        .mockRejectedValueOnce(
          new Error('connection to db-internal.local:5432 failed'),
        );

      const res = await request(http).get('/coins').expect(500);

      expect(res.body).toEqual({
        statusCode: 500,
        message: 'Internal server error',
      });
      expect(JSON.stringify(res.body)).not.toContain('db-internal');
    });

    it('does not expose write methods', async () => {
      await request(http).post('/coins').send({}).expect(404);
      await request(http).delete(`/coins/${COIN_A}`).expect(404);
    });

    it('rate limits each client', async () => {
      const limited = await createApp({ THROTTLE_LIMIT: '3' });
      const server = limited.getHttpServer() as App;
      for (let i = 0; i < 3; i++) {
        await request(server).get('/coins').expect(200);
      }
      const res = await request(server).get('/coins').expect(429);
      expect(res.headers['retry-after']).toBeDefined();
      await limited.close();
    });
  });
});
