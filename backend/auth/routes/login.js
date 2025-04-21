import bcrypt from 'bcrypt';

export function loginRoutes(fastify) {
  fastify.post('/login', {
    schema: {
      body: {
        type: 'object',
        required: ['email', 'password'],
        properties: {
          email: { type: 'string', format: 'email' },
          password: { type: 'string' }
        }
      }
    }
  }, async (req, reply) => {
    const { email, password } = req.body;

    try {
      const result = await fastify.pg.query('SELECT * FROM users WHERE email = $1', [email]);

      if (result.rowCount === 0) {
        return reply.code(401).send({ error: 'Invalid credentials' });
      }

      const user = result.rows[0];
      const valid = await bcrypt.compare(password, user.password);

      if (!valid) {
        return reply.code(401).send({ error: 'Invalid credentials' });
      }

      const token = fastify.jwt.sign({
        id: user.id,
        email: user.email
      });

      return reply.send({ token });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during login' });
    }
  });
}
