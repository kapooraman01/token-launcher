import { Log } from 'ethers';
import { ChainService } from '../chain/chain.service';
import { isRangeError, LogFetcher } from './log-fetcher.service';

function fakeLog(blockNumber: number): Log {
  return { blockNumber } as Log;
}

function createFetcher(provider: Record<string, jest.Mock>): LogFetcher {
  const fetcher = new LogFetcher({ provider } as unknown as ChainService);
  fetcher.retryOptions = { attempts: 3, baseDelayMs: 0, maxDelayMs: 0 };
  return fetcher;
}

describe('isRangeError', () => {
  it.each([
    'query returned more than 10000 results',
    'block range is too wide',
    'exceed maximum block range: 5000',
    'Log response size exceeded.',
  ])('recognises "%s"', (message) => {
    expect(isRangeError(new Error(message))).toBe(true);
    expect(
      isRangeError({ message: 'could not coalesce', error: { message } }),
    ).toBe(true);
  });

  it('does not treat other failures as range errors', () => {
    expect(isRangeError(new Error('ECONNRESET'))).toBe(false);
    expect(isRangeError(undefined)).toBe(false);
  });
});

describe('LogFetcher', () => {
  it('fetches a range in one call when the RPC accepts it', async () => {
    const getLogs = jest.fn().mockResolvedValue([fakeLog(5)]);
    const fetcher = createFetcher({ getLogs });

    const logs = await fetcher.getLogs(1, 10, ['0xa', '0xb']);

    expect(logs).toEqual([fakeLog(5)]);
    expect(getLogs).toHaveBeenCalledWith({
      fromBlock: 1,
      toBlock: 10,
      topics: [['0xa', '0xb']],
    });
  });

  it('splits a range the RPC rejects as too large and keeps chain order', async () => {
    const getLogs = jest.fn(
      ({ fromBlock, toBlock }: { fromBlock: number; toBlock: number }) => {
        if (toBlock - fromBlock > 2) {
          return Promise.reject(new Error('block range too large'));
        }
        return Promise.resolve([fakeLog(fromBlock), fakeLog(toBlock)]);
      },
    );
    const fetcher = createFetcher({ getLogs });

    const logs = await fetcher.getLogs(0, 7, ['0xa']);

    expect(logs.map((log) => log.blockNumber)).toEqual([
      0, 1, 2, 3, 4, 5, 6, 7,
    ]);
  });

  it('retries transient errors and then succeeds', async () => {
    const getLogs = jest
      .fn()
      .mockRejectedValueOnce(new Error('ECONNRESET'))
      .mockRejectedValueOnce(new Error('rate limited'))
      .mockResolvedValue([]);
    const fetcher = createFetcher({ getLogs });

    await expect(fetcher.getLogs(1, 1, ['0xa'])).resolves.toEqual([]);
    expect(getLogs).toHaveBeenCalledTimes(3);
  });

  it('gives up after the configured attempts', async () => {
    const getLogs = jest.fn().mockRejectedValue(new Error('ECONNRESET'));
    const fetcher = createFetcher({ getLogs });

    await expect(fetcher.getLogs(1, 1, ['0xa'])).rejects.toThrow('ECONNRESET');
    expect(getLogs).toHaveBeenCalledTimes(3);
  });

  it('rethrows a range error for a single block that cannot be split', async () => {
    const getLogs = jest.fn().mockRejectedValue(new Error('too many results'));
    const fetcher = createFetcher({ getLogs });

    await expect(fetcher.getLogs(4, 4, ['0xa'])).rejects.toThrow('too many');
    expect(getLogs).toHaveBeenCalledTimes(1);
  });

  it('fetches each distinct block header once', async () => {
    const getBlock = jest.fn((number: number) =>
      Promise.resolve({ number, hash: `0x${number}`, timestamp: number * 10 }),
    );
    const fetcher = createFetcher({ getBlock });

    const headers = await fetcher.getBlockHeaders([3, 1, 3, 2]);

    expect(getBlock).toHaveBeenCalledTimes(3);
    expect(headers.get(3)).toEqual({ number: 3, hash: '0x3', timestamp: 30 });
  });

  it('fails when a block is missing', async () => {
    const getBlock = jest.fn().mockResolvedValue(null);
    const fetcher = createFetcher({ getBlock });

    await expect(fetcher.getBlockHeader(9)).rejects.toThrow(
      'Block 9 not found',
    );
  });
});
