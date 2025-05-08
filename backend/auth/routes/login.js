import bcrypt from 'bcrypt';
import { v4 as uuidv4 } from 'uuid';

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
      const result = await fastify.pg.query(
        'SELECT id, password FROM users WHERE email = $1',
        [email]
      );

      if (result.rowCount === 0) {
        return reply.code(401).send({ error: 'Invalid credentials' });
      }

      const user = result.rows[0];
      const valid = await bcrypt.compare(password, user.password);

      if (!valid) {
        return reply.code(401).send({ error: 'Invalid credentials' });
      }

      // Génération de l'access token (JWT) court
      const accessToken = fastify.jwt.sign(
        { id: user.id, email },
        { expiresIn: '1h' }
      );

      // Génération d'un refresh token aléatoire UUID
      const refreshToken = uuidv4();
      const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000); // 30 jours

      // Stockage du refresh token en base
      await fastify.pg.query(
        'INSERT INTO refresh_tokens(user_id, token, expires_at) VALUES($1, $2, $3)',
        [user.id, refreshToken, expiresAt]
      );

      // Envoi des deux tokens
      return reply.send({
        accessToken,
        refreshToken
      });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during login' });
    }
  });
}