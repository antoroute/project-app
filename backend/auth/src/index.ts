import type { FastifyPluginAsync } from 'fastify';

import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';

import { loadConfig } from './config.js';
import dbPlugin from './plugins/db.js';
import enforceVersion from './middlewares/enforceVersion.js';
import validateAppSecret from './middlewares/validateAppSecret.js';
import authRoutes from './routes/auth.js';

async function build() {
  const config = loadConfig();
  const app = Fastify({ logger: true });

  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  const rateLimitPlugin = rateLimit as unknown as FastifyPluginAsync<{ max: number; timeWindow: string }>;
  await app.register(rateLimitPlugin, {
    max: 100,
    timeWindow: '1 minute'
  });

  await app.register(fastifyJwt, {
    secret: config.jwtSecret
    // NOTE: pas d'issuer/subject ici. On mettra iss/sub dans le payload lors du sign().
  });

  app.decorate('authenticate', async (req: any, reply: any) => {
    try { await req.jwtVerify(); }
    catch { reply.code(401).send({ error: 'unauthorized' }); }
  });

  await app.register(dbPlugin, { connectionString: config.databaseUrl });

  app.get('/health', async () => ({ ok: true }));

  await app.register(enforceVersion);
  await app.register(validateAppSecret, { appSecret: config.appSecret });
  await app.register(authRoutes, { prefix: '/auth' });

  await app.listen({ port: config.port, host: '0.0.0.0' });
}
build().catch((e) => { console.error(e); process.exit(1); });
