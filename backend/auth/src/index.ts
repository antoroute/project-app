import type { FastifyPluginAsync } from 'fastify';

import Fastify from 'fastify';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';

import { loadConfig } from './config.js';
import { assertAccessClaims, registerJwt } from './security/jwt.js';
import dbPlugin from './plugins/db.js';
import enforceVersion from './middlewares/enforceVersion.js';
import validateAppSecret from './middlewares/validateAppSecret.js';
import authRoutes from './routes/auth.js';

const AUTH_BODY_LIMIT_BYTES = 16 * 1024;

async function build() {
  const config = loadConfig();
  const app = Fastify({
    logger: true,
    bodyLimit: AUTH_BODY_LIMIT_BYTES,
    ajv: { customOptions: { removeAdditional: false } },
  });

  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  const rateLimitPlugin = rateLimit as unknown as FastifyPluginAsync<{ max: number; timeWindow: string }>;
  await app.register(rateLimitPlugin, {
    max: 100,
    timeWindow: '1 minute'
  });

  await registerJwt(
    app,
    config.jwtAccessPrivateKey,
    config.jwtAccessPublicKey,
    config.jwtRefreshSecret,
  );

  app.decorate('authenticate', async (req: any, reply: any) => {
    try {
      const payload = await req.jwtVerify();
      req.user = assertAccessClaims(payload);
    } catch {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });

  await app.register(dbPlugin, { connectionString: config.databaseUrl });

  app.get('/health', async () => ({ ok: true }));

  await app.register(enforceVersion);
  await app.register(validateAppSecret, { appSecret: config.appSecret });
  await app.register(authRoutes, { prefix: '/auth' });

  await app.listen({ port: config.port, host: '0.0.0.0' });
}
build().catch((e) => { console.error(e); process.exit(1); });
