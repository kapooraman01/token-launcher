import { validateEnv } from './env.schema';

const validEnv = {
  DATABASE_URL: 'postgresql://launcher:launcher@127.0.0.1:5434/launcher',
  CHAIN_ID: '46630',
  RPC_URL: 'https://rpc.testnet.chain.robinhood.com',
  FACTORY_ADDRESS: '0xe7f1725e7734ce288f8367e1bb143e90bb3f0512',
  START_BLOCK: '123',
};

describe('validateEnv', () => {
  it('parses a valid environment and applies defaults', () => {
    const env = validateEnv(validEnv);

    expect(env.CHAIN_ID).toBe(46630);
    expect(env.START_BLOCK).toBe(123);
    expect(env.FACTORY_ADDRESS).toBe(
      '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
    );
    expect(env.NODE_ENV).toBe('development');
    expect(env.PORT).toBe(3000);
    expect(env.INDEXER_ENABLED).toBe(true);
    expect(env.CONFIRMATIONS).toBe(2);
    expect(env.CORS_ORIGINS).toEqual([]);
  });

  it('parses a comma-separated CORS origin list', () => {
    const env = validateEnv({
      ...validEnv,
      CORS_ORIGINS: 'https://app.example.com, http://localhost:5173',
    });
    expect(env.CORS_ORIGINS).toEqual([
      'https://app.example.com',
      'http://localhost:5173',
    ]);
  });

  it.each([
    ['DATABASE_URL', 'mysql://user@host/db'],
    ['CHAIN_ID', '1'],
    ['RPC_URL', 'ftp://rpc.example.com'],
    ['RPC_URL', 'wss://rpc.example.com'],
    ['FACTORY_ADDRESS', '0x1234'],
    ['START_BLOCK', '-1'],
    ['INDEXER_ENABLED', 'yes'],
    ['CORS_ORIGINS', 'not-a-url'],
  ])('rejects an invalid %s', (key, value) => {
    expect(() => validateEnv({ ...validEnv, [key]: value })).toThrow(key);
  });

  it.each(['DATABASE_URL', 'CHAIN_ID', 'RPC_URL', 'FACTORY_ADDRESS'])(
    'rejects a missing %s',
    (key) => {
      const env: Record<string, string> = { ...validEnv };
      delete env[key];
      expect(() => validateEnv(env)).toThrow(key);
    },
  );
});
