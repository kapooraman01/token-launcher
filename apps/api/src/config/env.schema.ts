import { getAddress, isAddress } from 'ethers';
import { z } from 'zod';
import { getChain } from '@token-launcher/shared';

const booleanString = z
  .enum(['true', 'false'])
  .transform((value) => value === 'true');

const address = z
  .string()
  .refine((value) => isAddress(value), 'must be a valid address')
  .transform((value) => getAddress(value));

export const envSchema = z.object({
  NODE_ENV: z
    .enum(['development', 'test', 'production'])
    .default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),

  DATABASE_URL: z.url({ protocol: /^postgres(ql)?$/ }),

  CHAIN_ID: z.coerce
    .number()
    .int()
    .refine((id) => {
      try {
        getChain(id);
        return true;
      } catch {
        return false;
      }
    }, 'must be a supported chain id'),
  RPC_URL: z.url({ protocol: /^https?$/ }),
  FACTORY_ADDRESS: address,
  START_BLOCK: z.coerce.number().int().min(0),

  INDEXER_ENABLED: booleanString.default(true),
  CONFIRMATIONS: z.coerce.number().int().min(0).max(1000).default(2),
  INDEXER_POLL_INTERVAL_MS: z.coerce
    .number()
    .int()
    .min(250)
    .max(60_000)
    .default(2000),
  INDEXER_MAX_BLOCK_RANGE: z.coerce
    .number()
    .int()
    .min(1)
    .max(100_000)
    .default(2000),

  CORS_ORIGINS: z
    .string()
    .default('')
    .transform((value) =>
      value
        .split(',')
        .map((origin) => origin.trim())
        .filter(Boolean),
    )
    .pipe(z.array(z.url({ protocol: /^https?$/ }))),
  THROTTLE_TTL_MS: z.coerce.number().int().min(1000).default(60_000),
  THROTTLE_LIMIT: z.coerce.number().int().min(1).default(120),
  TRUST_PROXY_HOPS: z.coerce.number().int().min(0).max(10).default(0),
});

export type Env = z.infer<typeof envSchema>;

export function validateEnv(config: Record<string, unknown>): Env {
  const result = envSchema.safeParse(config);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `  ${issue.path.join('.')}: ${issue.message}`)
      .join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  return result.data;
}
