// Service Auth minimal pour la v2 (ESM + TS)
// - JWT (HS256 par défaut ; passe à RS256 si tu préfères des clés privées/publiques)
// - Helmet, CORS, Rate-limit
// - /health et routes de base: register, login, refresh, me, logout

import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';

import dbPlugin from './plugins/db';
import enforceVersion from './middlewares/enforceVersion';
import authRoutes from './routes/auth';

async function build() {
  const app = Fastify({ logger: true });

  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  await app.register(rateLimit, { max: 100, timeWindow: '1 minute' });

  await app.register(fastifyJwt, {
    secret: process.env.JWT_SECRET || 'dev-secret',
    sign: { issuer: 'project-app', audience: 'messaging' }
  });

  // Expose a small helper for protected routes
  app.decorate('authenticate', async (req: any, reply: any) => {
    try { await req.jwtVerify(); } catch { reply.code(401).send({ error: 'unauthorized' }); }
  });

  await app.register(dbPlugin);

  // Health
  app.get('/health', async () => ({ ok: true }));

  // Enforce client version >= 2 for protected and significant routes
  await app.register(enforceVersion);

  // Auth API
  await app.register(authRoutes, { prefix: '/auth' });

  const port = Number(process.env.PORT || 3000);
  await app.listen({ port, host: '0.0.0.0' });
}

build().catch((e) => { console.error(e); process.exit(1); });
