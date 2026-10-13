import { AbiCoder, getAddress, Interface, Log, zeroPadValue } from 'ethers';
import {
  bondingCurveAbi,
  graduationLockerAbi,
  launchFactoryAbi,
} from '@token-launcher/shared';
import { decodeLogs, sanitizeText, TOPICS } from './event-decoder';

const factoryIface = new Interface(launchFactoryAbi);
const curveIface = new Interface(bondingCurveAbi);
const lockerIface = new Interface(graduationLockerAbi);

const FACTORY = getAddress('0x00000000000000000000000000000000000000f1');
const TOKEN = getAddress('0x00000000000000000000000000000000000000a1');
const CURVE = getAddress('0x00000000000000000000000000000000000000c1');
const CREATOR = getAddress('0x00000000000000000000000000000000000000e1');
const TRADER = getAddress('0x00000000000000000000000000000000000000b1');
const IMPOSTOR = getAddress('0x00000000000000000000000000000000000000dd');
const LOCKER = getAddress('0x0000000000000000000000000000000000002000');
const TRUSTED = { factory: FACTORY, locker: LOCKER };

function toLog(
  address: string,
  encoded: { data: string; topics: string[] },
  blockNumber: number,
  index: number,
): Log {
  return {
    address,
    data: encoded.data,
    topics: encoded.topics,
    blockNumber,
    blockHash: `0xblock${blockNumber}`,
    transactionHash: `0xtx${blockNumber}`,
    index,
  } as unknown as Log;
}

function coinCreatedLog(blockNumber = 1, index = 0, from = FACTORY): Log {
  const encoded = factoryIface.encodeEventLog('CoinCreated', [
    TOKEN,
    CURVE,
    CREATOR,
    'Test Coin',
    'TEST',
    4n * 10n ** 18n,
    95,
    30,
    5000,
    30,
  ]);
  return toLog(from, encoded, blockNumber, index);
}

function buyLog(blockNumber: number, index: number, from = CURVE): Log {
  const encoded = curveIface.encodeEventLog('Buy', [
    TRADER,
    100n,
    2000n,
    3n,
    1n,
    1_000_096n,
    5_000n,
  ]);
  return toLog(from, encoded, blockNumber, index);
}

function sellLog(blockNumber: number, index: number): Log {
  const encoded = curveIface.encodeEventLog('Sell', [
    TRADER,
    2000n,
    90n,
    2n,
    1n,
    1_000_003n,
    7_000n,
  ]);
  return toLog(CURVE, encoded, blockNumber, index);
}

describe('decodeLogs', () => {
  it('decodes a launch and accepts trades from its curve in the same batch', () => {
    const { events, ignored } = decodeLogs(
      [buyLog(1, 1), coinCreatedLog(1, 0)],
      TRUSTED,
      new Set(),
    );

    expect(ignored).toBe(0);
    expect(events.map((event) => event.kind)).toEqual(['CoinCreated', 'Trade']);
    expect(events[0]).toMatchObject({
      kind: 'CoinCreated',
      token: TOKEN,
      curve: CURVE,
      creator: CREATOR,
      name: 'Test Coin',
      symbol: 'TEST',
      targetRaise: 4n * 10n ** 18n,
      platformFeeBps: 95,
      antiSnipeDuration: 30,
      blockNumber: 1,
      logIndex: 0,
    });
  });

  it('maps Buy and Sell amounts to ethAmount and tokenAmount', () => {
    const { events } = decodeLogs(
      [buyLog(2, 0), sellLog(3, 0)],
      TRUSTED,
      new Set([CURVE]),
    );

    expect(events).toEqual([
      expect.objectContaining({
        side: 'BUY',
        trader: TRADER,
        ethAmount: 100n,
        tokenAmount: 2000n,
        virtualTokenReserve: 5_000n,
      }),
      expect.objectContaining({
        side: 'SELL',
        ethAmount: 90n,
        tokenAmount: 2000n,
        virtualTokenReserve: 7_000n,
      }),
    ]);
  });

  it('decodes CurveCompleted', () => {
    const encoded = curveIface.encodeEventLog('CurveCompleted', [42n]);
    const { events } = decodeLogs(
      [toLog(CURVE, encoded, 5, 2)],
      TRUSTED,
      new Set([CURVE]),
    );
    expect(events[0]).toMatchObject({
      kind: 'CurveCompleted',
      curve: CURVE,
      realEthReserve: 42n,
    });
  });

  it('ignores a CoinCreated event from any contract other than the factory', () => {
    const { events, ignored } = decodeLogs(
      [coinCreatedLog(1, 0, IMPOSTOR), buyLog(1, 1)],
      TRUSTED,
      new Set(),
    );
    expect(events).toEqual([]);
    expect(ignored).toBe(2);
  });

  it('ignores trades from a contract that is not one of our curves', () => {
    const { events, ignored } = decodeLogs(
      [buyLog(1, 0, IMPOSTOR)],
      TRUSTED,
      new Set([CURVE]),
    );
    expect(events).toEqual([]);
    expect(ignored).toBe(1);
  });

  it('never decodes malformed data from an impostor, so it cannot crash the indexer', () => {
    const garbage = toLog(
      IMPOSTOR,
      { data: '0xdeadbeef', topics: [TOPICS.buy] },
      1,
      0,
    );
    expect(() => decodeLogs([garbage], TRUSTED, new Set())).not.toThrow();
  });

  it('does not mutate the caller’s set of known curves', () => {
    const known = new Set<string>();
    decodeLogs([coinCreatedLog()], TRUSTED, known);
    expect(known.size).toBe(0);
  });

  it('survives a coin name with invalid UTF-8 and NUL bytes', () => {
    const data = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes', 'uint256', 'uint16', 'uint16', 'uint16', 'uint32'],
      ['0x4869ff00fe', '0x00414243', 1n, 0, 0, 0, 0],
    );
    const topics = [
      TOPICS.coinCreated,
      zeroPadValue(TOKEN, 32),
      zeroPadValue(CURVE, 32),
      zeroPadValue(CREATOR, 32),
    ];

    const { events } = decodeLogs(
      [toLog(FACTORY, { data, topics }, 1, 0)],
      TRUSTED,
      new Set(),
    );

    expect(events[0]).toMatchObject({ name: 'Hi\uFFFD\uFFFD', symbol: 'ABC' });
  });
});

describe('decodeLogs graduation', () => {
  const POOL_ID = `0x${'ab'.repeat(32)}`;

  function graduatedLog(from: string): Log {
    const encoded = lockerIface.encodeEventLog('Graduated', [
      TOKEN,
      POOL_ID,
      CREATOR,
      3_980_000_000_000_000_000n,
      201_000_000n * 10n ** 18n,
      123_456n,
    ]);
    return toLog(from, encoded, 9, 4);
  }

  it('decodes Graduated from our locker', () => {
    const { events, ignored } = decodeLogs(
      [graduatedLog(LOCKER)],
      TRUSTED,
      new Set(),
    );
    expect(ignored).toBe(0);
    expect(events[0]).toMatchObject({
      kind: 'CoinGraduated',
      token: TOKEN,
      poolId: POOL_ID,
      creator: CREATOR,
      ethAdded: 3_980_000_000_000_000_000n,
      tokensAdded: 201_000_000n * 10n ** 18n,
      liquidity: 123_456n,
      blockNumber: 9,
      logIndex: 4,
    });
  });

  it('ignores Graduated from any other contract', () => {
    const { events, ignored } = decodeLogs(
      [graduatedLog(IMPOSTOR), graduatedLog(FACTORY)],
      TRUSTED,
      new Set([IMPOSTOR]),
    );
    expect(events).toEqual([]);
    expect(ignored).toBe(2);
  });
});

describe('sanitizeText', () => {
  it('keeps valid UTF-8, including emoji', () => {
    expect(sanitizeText('0xf09f9a80')).toBe('🚀');
  });
});
