import bcrypt from 'bcrypt';

export function registerRoutes(fastify) {
  fastify.post('/register', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password', 'username'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string', minLength: 6 },
          username: { type: 'string', minLength: 3, maxLength: 30 }
        }
      }
    }
  }, async (req, reply) => {
    const { email, password, username } = req.body;

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

      await fastify.pg.query(
        'INSERT INTO users (email, username, password) VALUES ($1, $2, $3)',
        [email, username, hashedPassword]
      );

      return reply.code(201).send({ message: 'User registered' });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during registration' });
    }
  });
}