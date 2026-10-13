import {
  AbiCoder,
  dataSlice,
  getAddress,
  Interface,
  Log,
  toUtf8String,
  Utf8ErrorFuncs,
} from 'ethers';
import {
  bondingCurveAbi,
  graduationLockerAbi,
  launchFactoryAbi,
} from '@token-launcher/shared';

const factoryInterface = new Interface(launchFactoryAbi);
const curveInterface = new Interface(bondingCurveAbi);
const lockerInterface = new Interface(graduationLockerAbi);

export const TOPICS = {
  coinCreated: factoryInterface.getEvent('CoinCreated')!.topicHash,
  buy: curveInterface.getEvent('Buy')!.topicHash,
  sell: curveInterface.getEvent('Sell')!.topicHash,
  curveCompleted: curveInterface.getEvent('CurveCompleted')!.topicHash,
  graduated: lockerInterface.getEvent('Graduated')!.topicHash,
};

export const INDEXED_TOPICS = Object.values(TOPICS);

const CURVE_TOPICS = new Set([TOPICS.buy, TOPICS.sell, TOPICS.curveCompleted]);

export interface LogMeta {
  blockNumber: number;
  blockHash: string;
  txHash: string;
  logIndex: number;
}

export interface CoinCreatedEvent extends LogMeta {
  kind: 'CoinCreated';
  token: string;
  curve: string;
  creator: string;
  name: string;
  symbol: string;
  targetRaise: bigint;
  platformFeeBps: number;
  creatorFeeBps: number;
  antiSnipeFeeBps: number;
  antiSnipeDuration: number;
}

export interface TradeEvent extends LogMeta {
  kind: 'Trade';
  side: 'BUY' | 'SELL';
  curve: string;
  trader: string;
  ethAmount: bigint;
  tokenAmount: bigint;
  platformFee: bigint;
  creatorFee: bigint;
  virtualEthReserve: bigint;
  virtualTokenReserve: bigint;
}

export interface CurveCompletedEvent extends LogMeta {
  kind: 'CurveCompleted';
  curve: string;
  realEthReserve: bigint;
}

export interface CoinGraduatedEvent extends LogMeta {
  kind: 'CoinGraduated';
  token: string;
  poolId: string;
  creator: string;
  ethAdded: bigint;
  tokensAdded: bigint;
  liquidity: bigint;
}

export type IndexedEvent =
  CoinCreatedEvent | TradeEvent | CurveCompletedEvent | CoinGraduatedEvent;

/** The only contracts whose events are trusted, besides the curves `factory` created. */
export interface TrustedContracts {
  factory: string;
  locker: string;
}

export interface DecodeResult {
  events: IndexedEvent[];
  /** Logs with one of our topics that did not come from our factory or one of its curves. */
  ignored: number;
}

/**
 * Converts raw logs into events, in chain order. A log is only decoded if it was emitted by
 * `factory` (CoinCreated), by `locker` (Graduated), or by a curve the factory created, either
 * earlier (`knownCurves`) or earlier in this same batch. Logs from any other contract are counted
 * and discarded without being decoded, so a contract imitating our events can neither inject
 * data nor crash decoding.
 */
export function decodeLogs(
  logs: readonly Log[],
  { factory, locker }: TrustedContracts,
  knownCurves: ReadonlySet<string>,
): DecodeResult {
  const curves = new Set(knownCurves);
  const events: IndexedEvent[] = [];
  let ignored = 0;

  const ordered = [...logs].sort(
    (a, b) => a.blockNumber - b.blockNumber || a.index - b.index,
  );

  for (const log of ordered) {
    const emitter = getAddress(log.address);
    const topic = log.topics[0];

    if (topic === TOPICS.coinCreated && emitter === factory) {
      const event = decodeCoinCreated(log);
      curves.add(event.curve);
      events.push(event);
    } else if (topic === TOPICS.graduated && emitter === locker) {
      events.push(decodeGraduated(log));
    } else if (CURVE_TOPICS.has(topic) && curves.has(emitter)) {
      events.push(decodeCurveEvent(log, emitter));
    } else {
      ignored++;
    }
  }

  return { events, ignored };
}

function meta(log: Log): LogMeta {
  return {
    blockNumber: log.blockNumber,
    blockHash: log.blockHash,
    txHash: log.transactionHash,
    logIndex: log.index,
  };
}

function topicAddress(topic: string): string {
  return getAddress(dataSlice(topic, 12));
}

/** Decodes user-supplied text as lossy UTF-8 and removes NUL bytes, which Postgres rejects. */
export function sanitizeText(bytes: string): string {
  return toUtf8String(bytes, Utf8ErrorFuncs.replace).replace(/\0/g, '');
}

function decodeCoinCreated(log: Log): CoinCreatedEvent {
  // `string` and `bytes` share an ABI encoding; decoding as bytes avoids ethers throwing on
  // invalid UTF-8 in a creator-chosen name.
  const [name, symbol, targetRaise, platformFee, creatorFee, snipeFee, snipe] =
    AbiCoder.defaultAbiCoder().decode(
      ['bytes', 'bytes', 'uint256', 'uint16', 'uint16', 'uint16', 'uint32'],
      log.data,
    ) as unknown as [string, string, bigint, bigint, bigint, bigint, bigint];

  return {
    kind: 'CoinCreated',
    ...meta(log),
    token: topicAddress(log.topics[1]),
    curve: topicAddress(log.topics[2]),
    creator: topicAddress(log.topics[3]),
    name: sanitizeText(name),
    symbol: sanitizeText(symbol),
    targetRaise,
    platformFeeBps: Number(platformFee),
    creatorFeeBps: Number(creatorFee),
    antiSnipeFeeBps: Number(snipeFee),
    antiSnipeDuration: Number(snipe),
  };
}

function decodeGraduated(log: Log): CoinGraduatedEvent {
  const [ethAdded, tokensAdded, liquidity] = AbiCoder.defaultAbiCoder().decode(
    ['uint256', 'uint256', 'uint128'],
    log.data,
  ) as unknown as [bigint, bigint, bigint];
  return {
    kind: 'CoinGraduated',
    ...meta(log),
    token: topicAddress(log.topics[1]),
    poolId: log.topics[2],
    creator: topicAddress(log.topics[3]),
    ethAdded,
    tokensAdded,
    liquidity,
  };
}

function decodeCurveEvent(log: Log, curve: string): IndexedEvent {
  const parsed = curveInterface.parseLog(log);
  if (!parsed) throw new Error(`Undecodable log ${log.transactionHash}`);

  if (parsed.name === 'CurveCompleted') {
    return {
      kind: 'CurveCompleted',
      ...meta(log),
      curve,
      realEthReserve: parsed.args[0] as bigint,
    };
  }

  // Buy(buyer, ethSpent, tokensOut, ...) and Sell(seller, tokensIn, ethOut, ...) share a layout
  // apart from the order of the ETH and token amounts.
  const [trader, first, second, platformFee, creatorFee, vEth, vToken] =
    parsed.args.toArray() as [
      string,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
    ];
  const isBuy = parsed.name === 'Buy';
  return {
    kind: 'Trade',
    ...meta(log),
    side: isBuy ? 'BUY' : 'SELL',
    curve,
    trader: getAddress(trader),
    ethAmount: isBuy ? first : second,
    tokenAmount: isBuy ? second : first,
    platformFee,
    creatorFee,
    virtualEthReserve: vEth,
    virtualTokenReserve: vToken,
  };
}
