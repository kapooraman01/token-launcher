// Mirrors contracts/src/libraries/BondingCurveMath.sol. All values are raw uint256 amounts.
export const TOTAL_SUPPLY = 1_000_000_000n * 10n ** 18n;
export const CURVE_SUPPLY = 793_100_000n * 10n ** 18n;
export const POOL_SUPPLY = 206_900_000n * 10n ** 18n;
export const INITIAL_VIRTUAL_TOKEN_RESERVE = 1_073_000_000n * 10n ** 18n;
export const FINAL_VIRTUAL_TOKEN_RESERVE =
  INITIAL_VIRTUAL_TOKEN_RESERVE - CURVE_SUPPLY;

/** Starting virtual ETH reserve for a curve with the given target raise, rounded up. */
export function initialVirtualEth(targetRaise: bigint): bigint {
  const numerator = targetRaise * FINAL_VIRTUAL_TOKEN_RESERVE;
  return (numerator + CURVE_SUPPLY - 1n) / CURVE_SUPPLY;
}

/** Tokens sold so far, given the curve's current virtual token reserve. */
export function tokensSold(virtualTokenReserve: bigint): bigint {
  return INITIAL_VIRTUAL_TOKEN_RESERVE - virtualTokenReserve;
}
