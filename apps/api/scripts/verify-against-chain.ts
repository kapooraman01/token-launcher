// Compares what the running API reports with the chain itself, coin by coin. Used for staging
// sign-off: every coin's reserves, completion state and trade count must match exactly.
//
//   API_URL=http://localhost:3000 RPC_URL=https://rpc.testnet.chain.robinhood.com \
//     pnpm verify:chain
import { Contract, JsonRpcProvider } from 'ethers';
import { bondingCurveAbi } from '@token-launcher/shared';
import { TOPICS } from '../src/indexer/event-decoder';

interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

interface CoinItem {
  address: string;
  curveAddress: string;
  symbol: string;
  virtualEthReserve: string;
  virtualTokenReserve: string;
  completed: boolean;
  graduated: boolean;
  createdBlock: string;
}

const apiUrl = process.env.API_URL ?? 'http://localhost:3000';
const provider = new JsonRpcProvider(process.env.RPC_URL);

async function getAll<T>(path: string): Promise<T[]> {
  const items: T[] = [];
  let cursor: string | null = null;
  do {
    const separator = path.includes('?') ? '&' : '?';
    const url = `${apiUrl}${path}${separator}limit=100${cursor ? `&cursor=${cursor}` : ''}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`${url} returned ${response.status}`);
    const page = (await response.json()) as Page<T>;
    items.push(...page.items);
    cursor = page.nextCursor;
  } while (cursor);
  return items;
}

async function main(): Promise<void> {
  const coins = await getAll<CoinItem>('/coins');
  let mismatches = 0;

  for (const coin of coins) {
    const curve = new Contract(coin.curveAddress, bondingCurveAbi, provider);
    const [vEth, vToken, state] = (await Promise.all([
      curve.getFunction('virtualEthReserve')(),
      curve.getFunction('virtualTokenReserve')(),
      curve.getFunction('state')(),
    ])) as [bigint, bigint, bigint];
    const tradeLogs = await provider.getLogs({
      address: coin.curveAddress,
      fromBlock: Number(coin.createdBlock),
      topics: [[TOPICS.buy, TOPICS.sell]],
    });
    const trades = await getAll<unknown>(`/coins/${coin.address}/trades`);

    // After graduation the curve's virtual ETH resets; the API keeps the final value.
    const problems = [
      state < 2n &&
        vEth.toString() !== coin.virtualEthReserve &&
        'virtualEthReserve',
      vToken.toString() !== coin.virtualTokenReserve && 'virtualTokenReserve',
      state >= 1n !== coin.completed && 'completed',
      (state === 2n) !== coin.graduated && 'graduated',
      tradeLogs.length !== trades.length &&
        `trades (chain ${tradeLogs.length}, api ${trades.length})`,
    ].filter(Boolean);

    if (problems.length > 0) mismatches++;
    console.log(
      `${problems.length ? 'MISMATCH' : 'ok      '} ${coin.symbol.padEnd(10)} ${coin.address} ` +
        `${trades.length} trades${problems.length ? `: ${problems.join(', ')}` : ''}`,
    );
  }

  console.log(`\n${coins.length} coins checked, ${mismatches} mismatched`);
  process.exitCode = mismatches > 0 ? 1 : 0;
}

void main();
