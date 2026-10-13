import { ConfigModule } from '@nestjs/config';
import { Test, TestingModule } from '@nestjs/testing';
import {
  Contract,
  ContractTransactionResponse,
  Interface,
  parseEther,
  TransactionReceipt,
  Wallet,
} from 'ethers';
import { bondingCurveAbi, launchFactoryAbi } from '@token-launcher/shared';
import { validateEnv } from '../../src/config/env.schema';
import { PrismaClient } from '../../src/generated/prisma/client';
import { TOPICS } from '../../src/indexer/event-decoder';
import { IndexerModule } from '../../src/indexer/indexer.module';
import { IndexerService } from '../../src/indexer/indexer.service';
import { PrismaModule } from '../../src/prisma/prisma.module';
import { AnvilChain, LaunchContracts } from './anvil';

export const DEADLINE = 2n ** 62n;
const factoryIface = new Interface(launchFactoryAbi);

export interface LaunchedCoin {
  token: string;
  curve: Contract;
}

/** Drives launches and trades on a test chain and runs the indexer against it. */
export class LaunchHarness {
  /** First block the next indexer instance indexes. */
  startBlock: number;
  readonly modules: TestingModule[] = [];

  constructor(
    readonly chain: AnvilChain,
    readonly contracts: LaunchContracts,
    readonly prisma: PrismaClient,
  ) {
    this.startBlock = contracts.startBlock;
  }

  async createIndexer(): Promise<{
    indexer: IndexerService;
    module: TestingModule;
  }> {
    Object.assign(process.env, {
      CHAIN_ID: String(this.chain.chainId),
      RPC_URL: this.chain.url,
      FACTORY_ADDRESS: await this.contracts.factory.getAddress(),
      START_BLOCK: String(this.startBlock),
      CONFIRMATIONS: '0',
      INDEXER_ENABLED: 'false',
      INDEXER_MAX_BLOCK_RANGE: '5',
    });
    const module = await Test.createTestingModule({
      imports: [
        ConfigModule.forRoot({
          isGlobal: true,
          ignoreEnvFile: true,
          validate: validateEnv,
        }),
        PrismaModule,
        IndexerModule,
      ],
    }).compile();
    await module.init();
    this.modules.push(module);
    return { indexer: module.get(IndexerService), module };
  }

  async closeIndexers(): Promise<void> {
    await Promise.all(this.modules.map((module) => module.close()));
    this.modules.length = 0;
  }

  async syncAll(indexer: IndexerService): Promise<void> {
    for (let i = 0; i < 1000; i++) {
      if (await indexer.tick()) return;
    }
    throw new Error('Indexer did not catch up');
  }

  async send(
    contract: Contract,
    wallet: Wallet,
    method: string,
    ...args: unknown[]
  ): Promise<TransactionReceipt> {
    const fn = (contract.connect(wallet) as Contract).getFunction(method);
    const tx = (await fn(...args)) as ContractTransactionResponse;
    const receipt = await tx.wait();
    if (!receipt) throw new Error(`${method} was not mined`);
    return receipt;
  }

  async launch(creator: Wallet, value = 0n): Promise<LaunchedCoin> {
    const receipt = await this.send(
      this.contracts.factory,
      creator,
      'createCoin',
      'Test Coin',
      'TEST',
      0,
      DEADLINE,
      { value },
    );
    for (const log of receipt.logs) {
      const parsed = factoryIface.parseLog(log);
      if (parsed?.name === 'CoinCreated') {
        return {
          token: parsed.args.token as string,
          curve: new Contract(
            parsed.args.curve as string,
            bondingCurveAbi,
            this.chain.provider,
          ),
        };
      }
    }
    throw new Error('CoinCreated not found');
  }

  async buy(curve: Contract, wallet: Wallet, eth: string): Promise<void> {
    await this.send(curve, wallet, 'buy', 0, DEADLINE, {
      value: parseEther(eth),
    });
  }

  async sellHalf(coin: LaunchedCoin, wallet: Wallet): Promise<void> {
    const erc20 = new Contract(
      coin.token,
      [
        'function balanceOf(address) view returns (uint256)',
        'function approve(address,uint256) returns (bool)',
      ],
      this.chain.provider,
    );
    const balance = (await erc20.getFunction('balanceOf')(
      wallet.address,
    )) as bigint;
    const curve = await coin.curve.getAddress();
    await this.send(erc20, wallet, 'approve', curve, balance / 2n);
    await this.send(coin.curve, wallet, 'sell', balance / 2n, 0, DEADLINE);
  }

  /** Every indexed coin's reserves, state and trade count must equal the chain's. */
  async expectDatabaseMatchesChain(): Promise<void> {
    const coins = await this.prisma.coin.findMany();
    for (const coin of coins) {
      const curve = new Contract(
        coin.curveAddress,
        bondingCurveAbi,
        this.chain.provider,
      );
      const [vEth, vToken, state] = await Promise.all([
        curve.getFunction('virtualEthReserve')() as Promise<bigint>,
        curve.getFunction('virtualTokenReserve')() as Promise<bigint>,
        curve.getFunction('state')() as Promise<bigint>,
      ]);
      expect(coin.virtualTokenReserve.toFixed()).toBe(vToken.toString());
      expect(coin.completed).toBe(state >= 1n);
      expect(coin.graduated).toBe(state === 2n);
      if (state < 2n) {
        // After graduation the curve's virtual ETH resets; the database keeps the final value.
        expect(coin.virtualEthReserve.toFixed()).toBe(vEth.toString());
      }

      const tradeLogs = await this.chain.provider.getLogs({
        address: coin.curveAddress,
        fromBlock: this.startBlock,
        topics: [[TOPICS.buy, TOPICS.sell]],
      });
      expect(
        await this.prisma.trade.count({ where: { coinAddress: coin.address } }),
      ).toBe(tradeLogs.length);
    }
  }
}
