import { Injectable } from '@nestjs/common';
import { Contract, getAddress, Log } from 'ethers';
import { launchFactoryAbi } from '@token-launcher/shared';
import { ChainService } from '../chain/chain.service';
import { DEFAULT_RETRY, retry, RetryOptions } from './retry';

export interface BlockHeader {
  number: number;
  hash: string;
  timestamp: number;
}

const RANGE_ERROR =
  /block range|range is too|too many|more than \d+ results|limit exceeded|response size|exceeds? (the )?max/i;

/** True when the RPC rejected a getLogs call because the range or result set was too large. */
export function isRangeError(error: unknown): boolean {
  const err = error as { message?: unknown; error?: { message?: unknown } };
  const messages = [err?.message, err?.error?.message].filter(
    (message): message is string => typeof message === 'string',
  );
  return messages.some((message) => RANGE_ERROR.test(message));
}

@Injectable()
export class LogFetcher {
  retryOptions: RetryOptions = DEFAULT_RETRY;

  constructor(private readonly chain: ChainService) {}

  /**
   * Returns all logs in `[fromBlock, toBlock]` whose first topic is one of `topics`, from any
   * address, in chain order. Ranges the RPC refuses as too large are split in half recursively.
   */
  async getLogs(
    fromBlock: number,
    toBlock: number,
    topics: string[],
  ): Promise<Log[]> {
    try {
      return await retry(
        () =>
          this.chain.provider.getLogs({ fromBlock, toBlock, topics: [topics] }),
        this.retryOptions,
        (error) => !isRangeError(error),
      );
    } catch (error) {
      if (fromBlock >= toBlock || !isRangeError(error)) throw error;
      const middle = Math.floor((fromBlock + toBlock) / 2);
      const left = await this.getLogs(fromBlock, middle, topics);
      const right = await this.getLogs(middle + 1, toBlock, topics);
      return [...left, ...right];
    }
  }

  /** The GraduationLocker the factory deployed; its events are the only graduation records. */
  async readFactoryLocker(factory: string): Promise<string> {
    const contract = new Contract(
      factory,
      launchFactoryAbi,
      this.chain.provider,
    );
    const locker = await retry(
      () => contract.getFunction('locker')() as Promise<string>,
      this.retryOptions,
    );
    return getAddress(locker);
  }

  async getBlockNumber(): Promise<number> {
    return retry(() => this.chain.provider.getBlockNumber(), this.retryOptions);
  }

  async getBlockHeader(blockNumber: number): Promise<BlockHeader> {
    const header = await this.findBlockHeader(blockNumber);
    if (!header) throw new Error(`Block ${blockNumber} not found`);
    return header;
  }

  /** Returns null when the chain has no block at that height (for example after a reorg). */
  async findBlockHeader(blockNumber: number): Promise<BlockHeader | null> {
    const block = await retry(
      () => this.chain.provider.getBlock(blockNumber),
      this.retryOptions,
    );
    if (!block?.hash) return null;
    return {
      number: block.number,
      hash: block.hash,
      timestamp: block.timestamp,
    };
  }

  async getBlockHeaders(
    blockNumbers: number[],
    concurrency = 10,
  ): Promise<Map<number, BlockHeader>> {
    const headers = new Map<number, BlockHeader>();
    const queue = [...new Set(blockNumbers)];
    const workers = Array.from(
      { length: Math.min(concurrency, queue.length) },
      async () => {
        for (let next = queue.pop(); next !== undefined; next = queue.pop()) {
          headers.set(next, await this.getBlockHeader(next));
        }
      },
    );
    await Promise.all(workers);
    return headers;
  }
}
