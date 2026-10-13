import { ConfigService } from '@nestjs/config';
import { NestExpressApplication } from '@nestjs/platform-express';
import helmet from 'helmet';
import { Env } from './config/env.schema';

/** HTTP-level hardening shared by the real server and the e2e tests. */
export function configureApp(app: NestExpressApplication): void {
  const config = app.get<ConfigService<Env, true>>(ConfigService);

  app.use(helmet());
  app.disable('x-powered-by');

  const origins = config.get('CORS_ORIGINS', { infer: true });
  if (origins.length > 0) {
    app.enableCors({ origin: origins, methods: ['GET'], maxAge: 600 });
  }

  // Only trust X-Forwarded-For from this many proxies in front of the app; otherwise any client
  // could fake its IP and bypass rate limiting.
  app.set('trust proxy', config.get('TRUST_PROXY_HOPS', { infer: true }));

  app.enableShutdownHooks();
}
