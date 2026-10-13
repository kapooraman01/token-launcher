import { ConfigService } from '@nestjs/config';
import { Env } from '../config/env.schema';
import { ChainService } from './chain.service';

function createService(chainId: number): ChainService {
  const values: Partial<Env> = {
    CHAIN_ID: chainId,
    RPC_URL: 'http://127.0.0.1:8545',
    FACTORY_ADDRESS: '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512',
  };
  const config = {
    get: (key: keyof Env) => values[key],
  } as unknown as ConfigService<Env, true>;
  return new ChainService(config);
}

describe('ChainService', () => {
  it('accepts an RPC that reports the configured chain id', async () => {
    const service = createService(46630);
    const send = jest
      .spyOn(service.provider, 'send')
      .mockResolvedValue('0xb626');

    await expect(service.assertChainId()).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledWith('eth_chainId', []);
  });

  it('refuses to start when the RPC is on a different chain', async () => {
    const service = createService(46630);
    jest.spyOn(service.provider, 'send').mockResolvedValue('0x1237');

    await expect(service.assertChainId()).rejects.toThrow(
      'RPC chain id 4663 does not match configured CHAIN_ID 46630',
    );
  });
});
