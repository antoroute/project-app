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

    try {
      // Vérifie que l'utilisateur n'existe pas déjà
      const existing = await fastify.pg.query('SELECT 1 FROM users WHERE email = $1', [email]);
      if (existing.rowCount > 0) {
        return reply.code(409).send({ error: 'Email already registered' });
      }

      const hashedPassword = await bcrypt.hash(password, 12); // Sel intégré + cost élevé

      await fastify.pg.query(
        'INSERT INTO users (email, password) VALUES ($1, $2)',
        [email, hashedPassword]
      );

      return reply.code(201).send({ message: 'User registered' });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during registration' });
    }
  });
}
