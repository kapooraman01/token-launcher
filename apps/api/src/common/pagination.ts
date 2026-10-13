export const DEFAULT_PAGE_SIZE = 20;
export const MAX_PAGE_SIZE = 100;

export interface Page<T> {
  items: T[];
  nextCursor: string | null;
}

/** Splits a result fetched with `take: limit + 1` into a page and the cursor for the next one. */
export function toPage<T, R>(
  rows: T[],
  limit: number,
  cursorOf: (row: T) => string,
  present: (row: T) => R,
): Page<R> {
  const page = rows.slice(0, limit);
  const last = page.at(-1);
  return {
    items: page.map(present),
    nextCursor: rows.length > limit && last ? cursorOf(last) : null,
  };
}
