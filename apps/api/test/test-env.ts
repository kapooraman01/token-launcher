export const TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL ??
  'postgresql://launcher:launcher@127.0.0.1:5434/launcher_test?schema=public';

process.env.DATABASE_URL = TEST_DATABASE_URL;
process.env.NODE_ENV = 'test';
