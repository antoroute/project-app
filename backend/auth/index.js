/// Structure finale du service auth basé sur Fastify ///

// Fichier: /app/backend/auth/index.js
import Fastify from 'fastify';
import fastifyJWT from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import helmet from '@fastify/helmet';
import { registerRoutes } from './routes/register.js';
import { loginRoutes } from './routes/login.js';
import { verifyJWT } from './middlewares/auth.js';
import { connectDB } from './plugins/db.js';

const fastify = Fastify({ logger: true });

await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(fastifyJWT, {
  secret: process.env.JWT_SECRET,
  sign: { expiresIn: '1h' }
});

await connectDB(fastify); // connect fastify.pg to db

registerRoutes(fastify);
loginRoutes(fastify);

fastify.get('/api/health', async () => 'Auth OK');

fastify.get('/me', { preHandler: verifyJWT(fastify) }, async (req, reply) => {
  return { user: req.user };
});

try {
  await fastify.listen({ port: process.env.PORT || 3000, host: '0.0.0.0' });
  } catch (err) {
    fastify.log.error(err);
    process.exit(1);
  }
}