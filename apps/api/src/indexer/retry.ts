export interface RetryOptions {
  attempts: number;
  baseDelayMs: number;
  maxDelayMs: number;
}

export const DEFAULT_RETRY: RetryOptions = {
  attempts: 5,
  baseDelayMs: 500,
  maxDelayMs: 10_000,
};

/** Runs `fn`, retrying with exponential backoff while `shouldRetry` allows it. */
export async function retry<T>(
  fn: () => Promise<T>,
  options: RetryOptions,
  shouldRetry: (error: unknown) => boolean = () => true,
): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt >= options.attempts || !shouldRetry(error)) throw error;
      const delay = Math.min(
        options.baseDelayMs * 2 ** (attempt - 1),
        options.maxDelayMs,
      );
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
}
