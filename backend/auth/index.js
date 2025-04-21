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

fastify.get('/health', async () => 'Auth OK');

fastify.get('/me', {
  preHandler: verifyJWT(fastify)
}, async (req, reply) => {
  try {
    const { id } = req.user;

    // Récupère email + username
    const userResult = await fastify.pg.query(
      'SELECT id, email, username FROM users WHERE id = $1',
      [id]
    );

    if (userResult.rowCount === 0) {
      return reply.code(404).send({ error: 'User not found' });
    }

    // Récupère les groupes de l'utilisateur
    const groupResult = await fastify.pg.query(
      'SELECT group_id FROM user_groups WHERE user_id = $1',
      [id]
    );

    const user = userResult.rows[0];
    const groups = groupResult.rows.map(row => row.group_id);

    return reply.send({
      user: {
        ...user,
        groups
      }
    });

  } catch (err) {
    req.log.error(err);
    return reply.code(500).send({ error: 'Failed to fetch user info' });
  }
});


try {
  await fastify.listen({ port: process.env.PORT || 3000, host: '0.0.0.0' });
} catch (err) {
  fastify.log.error(err);
  process.exit(1);
}