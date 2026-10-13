import { CURVE_SUPPLY, tokensSold } from '@token-launcher/shared';
import { Coin, Trade } from '../generated/prisma/client';

/** All amounts are decimal strings of raw uint256 values (wei or token base units). */
export interface CoinResponse {
  address: string;
  curveAddress: string;
  creator: string;
  name: string;
  symbol: string;
  targetRaise: string;
  platformFeeBps: number;
  creatorFeeBps: number;
  antiSnipeFeeBps: number;
  antiSnipeDuration: number;
  virtualEthReserve: string;
  virtualTokenReserve: string;
  realEthReserve: string;
  tokensSold: string;
  curveSupply: string;
  progressBps: number;
  completed: boolean;
  graduated: boolean;
  graduatedBlock: string | null;
  /** Uniswap v4 pool id (bytes32), set once graduated. */
  poolId: string | null;
  poolEth: string | null;
  poolTokens: string | null;
  createdBlock: string;
  createdTxHash: string;
  createdAt: string;
}

export interface TradeResponse {
  id: string;
  side: 'BUY' | 'SELL';
  trader: string;
  ethAmount: string;
  tokenAmount: string;
  platformFee: string;
  creatorFee: string;
  virtualEthReserve: string;
  virtualTokenReserve: string;
  blockNumber: string;
  txHash: string;
  logIndex: number;
  timestamp: string;
}

export function presentCoin(coin: Coin): CoinResponse {
  const virtualEth = BigInt(coin.virtualEthReserve.toFixed());
  const virtualToken = BigInt(coin.virtualTokenReserve.toFixed());
  const sold = tokensSold(virtualToken);

  return {
    address: coin.address,
    curveAddress: coin.curveAddress,
    creator: coin.creator,
    name: coin.name,
    symbol: coin.symbol,
    targetRaise: coin.targetRaise.toFixed(),
    platformFeeBps: coin.platformFeeBps,
    creatorFeeBps: coin.creatorFeeBps,
    antiSnipeFeeBps: coin.antiSnipeFeeBps,
    antiSnipeDuration: coin.antiSnipeDuration,
    virtualEthReserve: virtualEth.toString(),
    virtualTokenReserve: virtualToken.toString(),
    realEthReserve: (
      virtualEth - BigInt(coin.initialVirtualEth.toFixed())
    ).toString(),
    tokensSold: sold.toString(),
    curveSupply: CURVE_SUPPLY.toString(),
    progressBps: Number((sold * 10_000n) / CURVE_SUPPLY),
    completed: coin.completed,
    graduated: coin.graduated,
    graduatedBlock: coin.graduatedBlock?.toString() ?? null,
    poolId: coin.poolId,
    poolEth: coin.poolEth?.toFixed() ?? null,
    poolTokens: coin.poolTokens?.toFixed() ?? null,
    createdBlock: coin.createdBlock.toString(),
    createdTxHash: coin.createdTxHash,
    createdAt: coin.createdAt.toISOString(),
  };
}

export function presentTrade(trade: Trade): TradeResponse {
  return {
    id: trade.id.toString(),
    side: trade.side,
    trader: trade.trader,
    ethAmount: trade.ethAmount.toFixed(),
    tokenAmount: trade.tokenAmount.toFixed(),
    platformFee: trade.platformFee.toFixed(),
    creatorFee: trade.creatorFee.toFixed(),
    virtualEthReserve: trade.virtualEthReserve.toFixed(),
    virtualTokenReserve: trade.virtualTokenReserve.toFixed(),
    blockNumber: trade.blockNumber.toString(),
    txHash: trade.txHash,
    logIndex: trade.logIndex,
    timestamp: trade.timestamp.toISOString(),
  };
}
