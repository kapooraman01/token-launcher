import { Injectable, NotFoundException } from '@nestjs/common';
import { getAddress } from 'ethers';
import { Page, toPage } from '../common/pagination';
import { PrismaService } from '../prisma/prisma.service';
import {
  CoinResponse,
  presentCoin,
  presentTrade,
  TradeResponse,
} from './coin.presenter';

@Injectable()
export class CoinsService {
  constructor(private readonly prisma: PrismaService) {}

  /** Coins, newest launch first. */
  async list(limit: number, cursor?: string): Promise<Page<CoinResponse>> {
    const coins = await this.prisma.coin.findMany({
      take: limit + 1,
      ...(cursor && { cursor: { address: getAddress(cursor) }, skip: 1 }),
      orderBy: [{ createdBlock: 'desc' }, { address: 'desc' }],
    });
    return toPage(coins, limit, (coin) => coin.address, presentCoin);
  }

  async get(address: string): Promise<CoinResponse> {
    const coin = await this.prisma.coin.findUnique({ where: { address } });
    if (!coin) throw new NotFoundException('Coin not found');
    return presentCoin(coin);
  }

  /** A coin's trades, newest first in chain order. */
  async trades(
    address: string,
    limit: number,
    cursor?: string,
  ): Promise<Page<TradeResponse>> {
    const exists = await this.prisma.coin.count({ where: { address } });
    if (!exists) throw new NotFoundException('Coin not found');

    const trades = await this.prisma.trade.findMany({
      where: { coinAddress: address },
      take: limit + 1,
      ...(cursor && { cursor: { id: BigInt(cursor) }, skip: 1 }),
      orderBy: [{ blockNumber: 'desc' }, { logIndex: 'desc' }],
    });
    return toPage(trades, limit, (trade) => trade.id.toString(), presentTrade);
  }
}
