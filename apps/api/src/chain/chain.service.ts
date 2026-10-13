import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JsonRpcProvider, Network } from 'ethers';
import { Env } from '../config/env.schema';

@Injectable()
export class ChainService implements OnModuleInit {
  private readonly logger = new Logger(ChainService.name);

  readonly chainId: number;
  readonly factoryAddress: string;
  readonly provider: JsonRpcProvider;

  constructor(config: ConfigService<Env, true>) {
    this.chainId = config.get('CHAIN_ID', { infer: true });
    this.factoryAddress = config.get('FACTORY_ADDRESS', { infer: true });
    // cacheTimeout -1: ethers otherwise reuses identical responses (block number, blocks) for
    // 250ms, and the indexer must never act on a stale view of the chain.
    this.provider = new JsonRpcProvider(
      config.get('RPC_URL', { infer: true }),
      this.chainId,
      { staticNetwork: Network.from(this.chainId), cacheTimeout: -1 },
    );
  }

  async onModuleInit(): Promise<void> {
    await this.assertChainId();
  }

  async assertChainId(): Promise<void> {
    const remote = Number(await this.provider.send('eth_chainId', []));
    if (remote !== this.chainId) {
      throw new Error(
        `RPC chain id ${remote} does not match configured CHAIN_ID ${this.chainId}`,
      );
    }
    this.logger.log(`Connected to chain ${this.chainId}`);
  }
}
