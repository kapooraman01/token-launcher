import { Injectable } from '@nestjs/common';
import {
  INITIAL_VIRTUAL_TOKEN_RESERVE,
  initialVirtualEth,
} from '@token-launcher/shared';
import { Prisma } from '../generated/prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { IndexedEvent } from './event-decoder';
import { BlockHeader } from './log-fetcher.service';

export const CHECKPOINT_RETENTION = 1000;

export interface Checkpoint {
  blockNumber: number;
  blockHash: string;
}

export interface BatchInput {
  indexerId: string;
  /** Cursor this batch was computed from; null when the indexer has never run. */
  expectedLastBlock: number | null;
  events: IndexedEvent[];
  headers: Map<number, BlockHeader>;
  toBlock: BlockHeader;
}

/** Another writer moved the cursor since this batch was read; the batch must be discarded. */
export class StaleCursorError extends Error {}

type Tx = Prisma.TransactionClient;

@Injectable()
export class IndexerStore {
  constructor(private readonly prisma: PrismaService) {}

  async getCursor(indexerId: string): Promise<Checkpoint | null> {
    const state = await this.prisma.indexerState.findUnique({
      where: { id: indexerId },
    });
    return state
      ? { blockNumber: Number(state.lastBlock), blockHash: state.lastBlockHash }
      : null;
  }

  async getCheckpoints(indexerId: string): Promise<Checkpoint[]> {
    const rows = await this.prisma.indexerCheckpoint.findMany({
      where: { indexerId },
      orderBy: { blockNumber: 'desc' },
      take: CHECKPOINT_RETENTION,
    });
    return rows.map((row) => ({
      blockNumber: Number(row.blockNumber),
      blockHash: row.blockHash,
    }));
  }

  /** Returns which of `addresses` are curves of coins already in the database. */
  async findKnownCurves(addresses: string[]): Promise<Set<string>> {
    if (addresses.length === 0) return new Set();
    const coins = await this.prisma.coin.findMany({
      where: { curveAddress: { in: addresses } },
      select: { curveAddress: true },
    });
    return new Set(coins.map((coin) => coin.curveAddress));
  }

  /** Writes a batch of events and advances the cursor to `toBlock`, all or nothing. */
  async applyBatch(input: BatchInput): Promise<void> {
    await this.prisma.$transaction(
      async (tx) => {
        await this.lockAndCheckCursor(
          tx,
          input.indexerId,
          input.expectedLastBlock,
        );

        for (const event of input.events) {
          const header = input.headers.get(event.blockNumber);
          if (!header) throw new Error(`Missing header ${event.blockNumber}`);
          await this.applyEvent(tx, event, new Date(header.timestamp * 1000));
        }

        await this.saveCursor(tx, input.indexerId, input.toBlock);
      },
      { timeout: 60_000 },
    );
  }

  /**
   * Removes everything indexed after `ancestor` (or everything, when null) and moves the cursor
   * back so those blocks are indexed again from the canonical chain.
   */
  async rewind(indexerId: string, ancestor: Checkpoint | null): Promise<void> {
    await this.prisma.$transaction(
      async (tx) => {
        await this.lock(tx, indexerId);
        const fork = BigInt(ancestor ? ancestor.blockNumber : -1);

        const affected = await tx.trade.findMany({
          where: { blockNumber: { gt: fork } },
          distinct: ['coinAddress'],
          select: { coinAddress: true },
        });
        await tx.trade.deleteMany({ where: { blockNumber: { gt: fork } } });
        await tx.coin.deleteMany({ where: { createdBlock: { gt: fork } } });
        await tx.coin.updateMany({
          where: { completedBlock: { gt: fork } },
          data: { completed: false, completedBlock: null },
        });
        await tx.coin.updateMany({
          where: { graduatedBlock: { gt: fork } },
          data: {
            graduated: false,
            graduatedBlock: null,
            poolId: null,
            poolEth: null,
            poolTokens: null,
          },
        });
        for (const { coinAddress } of affected) {
          await this.restoreReserves(tx, coinAddress);
        }

        await tx.indexerCheckpoint.deleteMany({
          where: { indexerId, blockNumber: { gt: fork } },
        });
        if (ancestor) {
          await tx.indexerState.update({
            where: { id: indexerId },
            data: {
              lastBlock: BigInt(ancestor.blockNumber),
              lastBlockHash: ancestor.blockHash,
            },
          });
        } else {
          await tx.indexerState.deleteMany({ where: { id: indexerId } });
        }
      },
      { timeout: 60_000 },
    );
  }

  private async applyEvent(
    tx: Tx,
    event: IndexedEvent,
    timestamp: Date,
  ): Promise<void> {
    switch (event.kind) {
      case 'CoinCreated':
        await tx.coin.create({
          data: {
            address: event.token,
            curveAddress: event.curve,
            creator: event.creator,
            name: event.name,
            symbol: event.symbol,
            targetRaise: event.targetRaise.toString(),
            initialVirtualEth: initialVirtualEth(event.targetRaise).toString(),
            platformFeeBps: event.platformFeeBps,
            creatorFeeBps: event.creatorFeeBps,
            antiSnipeFeeBps: event.antiSnipeFeeBps,
            antiSnipeDuration: event.antiSnipeDuration,
            virtualEthReserve: initialVirtualEth(event.targetRaise).toString(),
            virtualTokenReserve: INITIAL_VIRTUAL_TOKEN_RESERVE.toString(),
            createdBlock: BigInt(event.blockNumber),
            createdTxHash: event.txHash,
            createdAt: timestamp,
          },
        });
        return;
      case 'Trade': {
        const coin = await tx.coin.update({
          where: { curveAddress: event.curve },
          data: {
            virtualEthReserve: event.virtualEthReserve.toString(),
            virtualTokenReserve: event.virtualTokenReserve.toString(),
          },
          select: { address: true },
        });
        await tx.trade.create({
          data: {
            coinAddress: coin.address,
            side: event.side,
            trader: event.trader,
            ethAmount: event.ethAmount.toString(),
            tokenAmount: event.tokenAmount.toString(),
            platformFee: event.platformFee.toString(),
            creatorFee: event.creatorFee.toString(),
            virtualEthReserve: event.virtualEthReserve.toString(),
            virtualTokenReserve: event.virtualTokenReserve.toString(),
            blockNumber: BigInt(event.blockNumber),
            blockHash: event.blockHash,
            txHash: event.txHash,
            logIndex: event.logIndex,
            timestamp,
          },
        });
        return;
      }
      case 'CurveCompleted':
        await tx.coin.update({
          where: { curveAddress: event.curve },
          data: { completed: true, completedBlock: BigInt(event.blockNumber) },
        });
        return;
      case 'CoinGraduated':
        await tx.coin.update({
          where: { address: event.token },
          data: {
            graduated: true,
            graduatedBlock: BigInt(event.blockNumber),
            poolId: event.poolId,
            poolEth: event.ethAdded.toString(),
            poolTokens: event.tokensAdded.toString(),
          },
        });
        return;
    }
  }

  private async restoreReserves(tx: Tx, coinAddress: string): Promise<void> {
    const coin = await tx.coin.findUnique({ where: { address: coinAddress } });
    if (!coin) return;
    const last = await tx.trade.findFirst({
      where: { coinAddress },
      orderBy: [{ blockNumber: 'desc' }, { logIndex: 'desc' }],
    });
    await tx.coin.update({
      where: { address: coinAddress },
      data: last
        ? {
            virtualEthReserve: last.virtualEthReserve,
            virtualTokenReserve: last.virtualTokenReserve,
          }
        : {
            virtualEthReserve: coin.initialVirtualEth,
            virtualTokenReserve: INITIAL_VIRTUAL_TOKEN_RESERVE.toString(),
          },
    });
  }

  private async saveCursor(
    tx: Tx,
    indexerId: string,
    block: BlockHeader,
  ): Promise<void> {
    const data = { lastBlock: BigInt(block.number), lastBlockHash: block.hash };
    await tx.indexerState.upsert({
      where: { id: indexerId },
      create: { id: indexerId, ...data },
      update: data,
    });
    await tx.indexerCheckpoint.upsert({
      where: {
        indexerId_blockNumber: { indexerId, blockNumber: data.lastBlock },
      },
      create: { indexerId, blockNumber: data.lastBlock, blockHash: block.hash },
      update: { blockHash: block.hash },
    });
    await tx.indexerCheckpoint.deleteMany({
      where: {
        indexerId,
        blockNumber: { lte: data.lastBlock - BigInt(CHECKPOINT_RETENTION) },
      },
    });
  }

  /** Serialises writers across processes for the rest of the transaction. */
  private async lock(tx: Tx, indexerId: string): Promise<void> {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${indexerId}))`;
  }

  private async lockAndCheckCursor(
    tx: Tx,
    indexerId: string,
    expectedLastBlock: number | null,
  ): Promise<void> {
    await this.lock(tx, indexerId);
    const state = await tx.indexerState.findUnique({
      where: { id: indexerId },
    });
    const actual = state ? Number(state.lastBlock) : null;
    if (actual !== expectedLastBlock) {
      throw new StaleCursorError(
        `Cursor moved from ${expectedLastBlock} to ${actual}`,
      );
    }
  }
}
