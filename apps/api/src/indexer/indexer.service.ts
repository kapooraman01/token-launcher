import {
  Injectable,
  Logger,
  OnApplicationBootstrap,
  OnModuleDestroy,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { getAddress } from 'ethers';
import { ChainService } from '../chain/chain.service';
import { Env } from '../config/env.schema';
import { decodeLogs, INDEXED_TOPICS } from './event-decoder';
import { Checkpoint, IndexerStore, StaleCursorError } from './indexer.store';
import { LogFetcher } from './log-fetcher.service';

@Injectable()
export class IndexerService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly logger = new Logger(IndexerService.name);

  readonly indexerId: string;
  private readonly factory: string;
  private readonly startBlock: number;
  private readonly confirmations: number;
  private readonly maxBlockRange: number;
  private readonly pollIntervalMs: number;
  private readonly enabled: boolean;

  private locker?: string;
  private timer?: NodeJS.Timeout;
  private stopped = false;

  constructor(
    config: ConfigService<Env, true>,
    chain: ChainService,
    private readonly fetcher: LogFetcher,
    private readonly store: IndexerStore,
  ) {
    this.factory = chain.factoryAddress;
    this.indexerId = `${chain.chainId}:${this.factory}`;
    this.startBlock = config.get('START_BLOCK', { infer: true });
    this.confirmations = config.get('CONFIRMATIONS', { infer: true });
    this.maxBlockRange = config.get('INDEXER_MAX_BLOCK_RANGE', { infer: true });
    this.pollIntervalMs = config.get('INDEXER_POLL_INTERVAL_MS', {
      infer: true,
    });
    this.enabled = config.get('INDEXER_ENABLED', { infer: true });
  }

  onApplicationBootstrap(): void {
    if (!this.enabled) {
      this.logger.log('Indexer disabled');
      return;
    }
    this.logger.log(`Indexing ${this.indexerId} from block ${this.startBlock}`);
    this.schedule(0);
  }

  onModuleDestroy(): void {
    this.stopped = true;
    clearTimeout(this.timer);
  }

  private schedule(delayMs: number): void {
    if (this.stopped) return;
    this.timer = setTimeout(() => void this.loop(), delayMs);
  }

  private async loop(): Promise<void> {
    let caughtUp = true;
    try {
      caughtUp = await this.tick();
    } catch (error) {
      if (error instanceof StaleCursorError) {
        this.logger.warn(error.message);
      } else {
        this.logger.error('Indexer tick failed', error as Error);
      }
    }
    this.schedule(caughtUp ? this.pollIntervalMs : 0);
  }

  /**
   * Indexes at most one block range. Returns true when the database has caught up with the
   * newest block that has `CONFIRMATIONS` blocks on top of it.
   */
  async tick(): Promise<boolean> {
    this.locker ??= await this.fetcher.readFactoryLocker(this.factory);
    const cursor = await this.store.getCursor(this.indexerId);
    if (cursor && (await this.handleReorg(cursor))) return false;

    const lastBlock = cursor ? cursor.blockNumber : this.startBlock - 1;
    const safeHead = (await this.fetcher.getBlockNumber()) - this.confirmations;
    const fromBlock = lastBlock + 1;
    if (fromBlock > safeHead) return true;
    const toBlock = Math.min(fromBlock + this.maxBlockRange - 1, safeHead);

    const logs = await this.fetcher.getLogs(fromBlock, toBlock, INDEXED_TOPICS);
    const emitters = [...new Set(logs.map((log) => getAddress(log.address)))];
    const knownCurves = await this.store.findKnownCurves(emitters);
    const { events, ignored } = decodeLogs(
      logs,
      { factory: this.factory, locker: this.locker },
      knownCurves,
    );
    if (ignored > 0) {
      this.logger.warn(`Ignored ${ignored} logs from unknown contracts`);
    }

    const headers = await this.fetcher.getBlockHeaders([
      ...events.map((event) => event.blockNumber),
      toBlock,
    ]);
    for (const event of events) {
      if (headers.get(event.blockNumber)?.hash !== event.blockHash) {
        throw new Error(
          `Block ${event.blockNumber} changed while fetching; retrying range`,
        );
      }
    }

    await this.store.applyBatch({
      indexerId: this.indexerId,
      expectedLastBlock: cursor ? cursor.blockNumber : null,
      events,
      headers,
      toBlock: headers.get(toBlock)!,
    });
    this.logger.log(
      `Indexed blocks ${fromBlock}-${toBlock} (${events.length} events)`,
    );
    return toBlock === safeHead;
  }

  /** Rewinds to the newest checkpoint still on the canonical chain if the cursor block changed. */
  private async handleReorg(cursor: Checkpoint): Promise<boolean> {
    if (await this.isCanonical(cursor)) return false;

    this.logger.warn(`Reorg detected at block ${cursor.blockNumber}`);
    let ancestor: Checkpoint | null = null;
    for (const checkpoint of await this.store.getCheckpoints(this.indexerId)) {
      if (await this.isCanonical(checkpoint)) {
        ancestor = checkpoint;
        break;
      }
    }
    if (!ancestor) {
      this.logger.error('No canonical checkpoint found; reindexing from start');
    }
    await this.store.rewind(this.indexerId, ancestor);
    this.logger.warn(`Rewound to block ${ancestor?.blockNumber ?? 'start'}`);
    return true;
  }

  private async isCanonical(checkpoint: Checkpoint): Promise<boolean> {
    const header = await this.fetcher.findBlockHeader(checkpoint.blockNumber);
    return header?.hash === checkpoint.blockHash;
  }
}
