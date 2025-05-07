import bcrypt from 'bcrypt';

export function registerRoutes(fastify) {
  fastify.post('/register', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password', 'username', 'publicKey'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string', minLength: 6 },
          username: { type: 'string', minLength: 3, maxLength: 20 },
          publicKey: { type: 'string', minLength: 700 }
        }
      }
    }
  }, async (req, reply) => {
    const { email, password, username, publicKey } = req.body;

    try {
      const existingEmail = await fastify.pg.query('SELECT 1 FROM users WHERE email = $1', [email]);
      if (existingEmail.rowCount > 0) {
        return reply.code(409).send({ error: 'Email already registered' });
      }

      const existingUsername = await fastify.pg.query('SELECT 1 FROM users WHERE username = $1', [username]);
      if (existingUsername.rowCount > 0) {
        return reply.code(409).send({ error: 'Username already taken' });
      }

      const hashedPassword = await bcrypt.hash(password, 12);

      const result = await fastify.pg.query(
        'INSERT INTO users (email, username, password, public_key) VALUES ($1, $2, $3, $4) RETURNING id',
        [email, username, hashedPassword, publicKey]
      );

      return reply.code(201).send({ id: result.rows[0].id });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during registration' });
    }
  });
}