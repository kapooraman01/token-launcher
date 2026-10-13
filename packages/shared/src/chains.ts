export interface ChainConfig {
  id: number;
  name: string;
  rpcUrl: string;
  explorerUrl: string;
}

export const ROBINHOOD_MAINNET: ChainConfig = {
  id: 4663,
  name: 'Robinhood Chain',
  rpcUrl: 'https://rpc.mainnet.chain.robinhood.com',
  explorerUrl: 'https://robinhoodchain.blockscout.com',
};

export const ROBINHOOD_TESTNET: ChainConfig = {
  id: 46630,
  name: 'Robinhood Chain Testnet',
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  explorerUrl: 'https://explorer.testnet.chain.robinhood.com',
};

export const LOCAL_ANVIL: ChainConfig = {
  id: 31337,
  name: 'Local Anvil',
  rpcUrl: 'http://127.0.0.1:8545',
  explorerUrl: '',
};

const CHAINS: ReadonlyMap<number, ChainConfig> = new Map(
  [ROBINHOOD_MAINNET, ROBINHOOD_TESTNET, LOCAL_ANVIL].map((chain) => [
    chain.id,
    chain,
  ]),
);

export function getChain(chainId: number): ChainConfig {
  const chain = CHAINS.get(chainId);
  if (!chain) {
    throw new Error(`Unsupported chain id: ${chainId}`);
  }
  return chain;
}
