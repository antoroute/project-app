import bcrypt from 'bcrypt';

export function registerRoutes(fastify) {
  fastify.post('/register', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string', minLength: 6 }
        }
      }
    }
  }, async (req, reply) => {
    const { email, password } = req.body;
    const hashed = await bcrypt.hash(password, 10);
    const publicKey = 'dummy_key'; // à remplacer par une clé RSA côté client

    try {
      await fastify.pg.query(
        'INSERT INTO users (email, password, public_key) VALUES ($1, $2, $3)',
        [email, hashed, publicKey]
      );
      return reply.code(201).send({ message: 'User registered' });
    } catch (err) {
      req.log.error(err);
      return reply.code(400).send({ error: 'Registration failed' });
    }
  });
}
