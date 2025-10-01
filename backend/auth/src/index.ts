import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';

import dbPlugin from './plugins/db.js';
import enforceVersion from './middlewares/enforceVersion.js';
import authRoutes from './routes/auth.js';

async function build() {
  const app = Fastify({ logger: true });

  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  await app.register(rateLimit, { max: 100, timeWindow: '1 minute' });

  await app.register(fastifyJwt, {
    secret: process.env.JWT_SECRET || 'dev-secret',
    sign: { issuer: 'project-app', audience: 'messaging' }
  });

  // Helper d’auth pour routes protégées
  app.decorate('authenticate', async (req: any, reply: any) => {
    try { await req.jwtVerify(); }
    catch { return reply.code(401).send({ error: 'unauthorized' }); }
  });

  // DB + santé
  await app.register(dbPlugin);
  app.get('/health', async () => ({ ok: true }));

  // Enforcer version client + routes Auth
  await app.register(enforceVersion);
  await app.register(authRoutes, { prefix: '/auth' });

  const port = Number(process.env.PORT || 3000);
  await app.listen({ host: '0.0.0.0', port });
}

build().catch((e) => { console.error(e); process.exit(1); });
