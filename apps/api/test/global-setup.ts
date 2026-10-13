import { execSync } from 'node:child_process';
import { join } from 'node:path';
import { TEST_DATABASE_URL } from './test-env';

export default function globalSetup(): void {
  execSync('pnpm exec prisma migrate deploy', {
    cwd: join(__dirname, '..'),
    env: { ...process.env, DATABASE_URL: TEST_DATABASE_URL },
    stdio: 'inherit',
  });

  // The Anvil tests deploy contracts and test mocks from Foundry's build output, which other
  // tools (such as Slither) may have cleaned or partially rebuilt.
  execSync('forge build --quiet', {
    cwd: join(__dirname, '..', '..', '..', 'contracts'),
    stdio: 'inherit',
  });
}
