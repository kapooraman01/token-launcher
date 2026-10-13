import { ChildProcess, spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  AbiCoder,
  concat,
  Contract,
  ContractFactory,
  getCreate2Address,
  getCreateAddress,
  InterfaceAbi,
  JsonRpcProvider,
  keccak256,
  Network,
  parseEther,
  toBeHex,
  Wallet,
  zeroPadValue,
} from 'ethers';

const FORGE_OUT = join(__dirname, '..', '..', '..', '..', 'contracts', 'out');
const ARB_SYS = '0x0000000000000000000000000000000000000064';

export const ROBINHOOD_TESTNET_RPC =
  process.env.ROBINHOOD_TESTNET_RPC ??
  'https://rpc.testnet.chain.robinhood.com';
/** Uniswap v4 PoolManager, at the same address on Robinhood Chain mainnet and testnet. */
export const POOL_MANAGER = '0x8366a39CC670B4001A1121B8F6A443A643e40951';

/** Anvil's default funded development keys. Never use these anywhere else. */
export const ANVIL_KEYS = [
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
  '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
];

interface Artifact {
  abi: InterfaceAbi;
  bytecode: string;
  deployedBytecode: string;
}

export function loadArtifact(name: string): Artifact {
  const json = JSON.parse(
    readFileSync(join(FORGE_OUT, `${name}.sol`, `${name}.json`), 'utf8'),
  ) as {
    abi: InterfaceAbi;
    bytecode: { object: string };
    deployedBytecode: { object: string };
  };
  return {
    abi: json.abi,
    bytecode: json.bytecode.object,
    deployedBytecode: json.deployedBytecode.object,
  };
}

export interface AnvilChain {
  url: string;
  chainId: number;
  provider: JsonRpcProvider;
  wallets: Wallet[];
  stop(): Promise<void>;
}

/**
 * Starts a fresh Anvil chain with MockArbSys installed at the ArbSys precompile address. With
 * `forkUrl`, the chain is a fork of that network (so Uniswap v4 is available) and keeps its
 * chain id.
 */
export async function startAnvil(
  port: number,
  forkUrl?: string,
): Promise<AnvilChain> {
  const url = `http://127.0.0.1:${port}`;
  const chainId = forkUrl ? 46630 : 31337;
  const args = ['--port', String(port), '--silent'];
  if (forkUrl) args.push('--fork-url', forkUrl);
  const child: ChildProcess = spawn(process.env.ANVIL_BIN ?? 'anvil', args, {
    stdio: 'ignore',
  });

  // ethers caches identical requests for 250ms by default, which hands out stale nonces on a
  // chain that mines every transaction instantly.
  const provider = new JsonRpcProvider(url, chainId, {
    staticNetwork: Network.from(chainId),
    pollingInterval: 50,
    cacheTimeout: -1,
  });
  const stop = async (): Promise<void> => {
    provider.destroy();
    if (child.exitCode !== null) return;
    const exited = new Promise((resolve) => child.once('exit', resolve));
    child.kill();
    await exited;
  };

  try {
    for (let attempt = 0; ; attempt++) {
      try {
        await provider.getBlockNumber();
        break;
      } catch (error) {
        if (attempt > 300) throw error;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
    await provider.send('anvil_setCode', [
      ARB_SYS,
      loadArtifact('MockArbSys').deployedBytecode,
    ]);
  } catch (error) {
    await stop();
    throw error;
  }

  return {
    url,
    chainId,
    provider,
    wallets: ANVIL_KEYS.map((key) => new Wallet(key, provider)),
    stop,
  };
}

export async function deploy(
  name: string,
  wallet: Wallet,
  args: unknown[] = [],
): Promise<Contract> {
  const artifact = loadArtifact(name);
  const factory = new ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract as Contract;
}

export interface LaunchContracts {
  vault: Contract;
  factory: Contract;
  locker: Contract;
  startBlock: number;
}

/** Finds the CREATE2 salt that gives the factory's locker the beforeInitialize hook address. */
export function mineLockerSalt(factory: string, lockerArgs: unknown[]): string {
  const initCodeHash = keccak256(
    concat([
      loadArtifact('GraduationLocker').bytecode,
      AbiCoder.defaultAbiCoder().encode(
        ['address', 'address', 'uint24', 'int24', 'uint16'],
        lockerArgs,
      ),
    ]),
  );
  for (let i = 0n; i < 1_000_000n; i++) {
    const salt = zeroPadValue(toBeHex(i), 32);
    const locker = getCreate2Address(factory, salt, initCodeHash);
    if ((BigInt(locker) & 0x3fffn) === 0x2000n) return salt;
  }
  throw new Error('No locker salt found');
}

/** Deploys the FeeVault and LaunchFactory the same way script/Deploy.s.sol does. */
export async function deployLaunch(deployer: Wallet): Promise<LaunchContracts> {
  const vault = await deploy('FeeVault', deployer, [deployer.address]);
  const vaultAddress = await vault.getAddress();
  const predicted = getCreateAddress({
    from: deployer.address,
    nonce: await deployer.getNonce(),
  });
  const pool = { fee: 10_000, tickSpacing: 200, creatorShareBps: 5_000 };
  const lockerSalt = mineLockerSalt(predicted, [
    POOL_MANAGER,
    vaultAddress,
    pool.fee,
    pool.tickSpacing,
    pool.creatorShareBps,
  ]);

  const factory = await deploy('LaunchFactory', deployer, [
    {
      owner: deployer.address,
      feeVault: vaultAddress,
      targetRaise: parseEther('4'),
      platformFeeBps: 95,
      creatorFeeBps: 30,
      antiSnipeFeeBps: 5000,
      antiSnipeDuration: 30,
      maxCreatorBuyBps: 500,
      maxCreatorBuyEth: parseEther('0.5'),
      poolManager: POOL_MANAGER,
      lockerSalt,
      poolFee: pool.fee,
      tickSpacing: pool.tickSpacing,
      lockerCreatorShareBps: pool.creatorShareBps,
      graduationFee: parseEther('0.02'),
      graduationReward: parseEther('0.001'),
    },
  ]);
  if ((await factory.getAddress()) !== predicted) {
    throw new Error('Factory address prediction failed');
  }
  const lockerAddress = (await factory.getFunction('locker')()) as string;
  return {
    vault,
    factory,
    locker: new Contract(
      lockerAddress,
      loadArtifact('GraduationLocker').abi,
      deployer.provider,
    ),
    startBlock: (await factory.deploymentTransaction()!.wait())!.blockNumber,
  };
}
