import { createHash } from 'crypto';

export function refreshRoutes(fastify) {
  fastify.post('/refresh', {
    schema: {
      body: {
        type: 'object',
        required: ['refreshToken'],
        properties: {
          refreshToken: { type: 'string' }
        }
      }
    }
  }, async (req, reply) => {
    const { refreshToken } = req.body;

    try {
      // Hash du token reçu
      const tokenHash = createHash('sha256').update(refreshToken).digest('hex');

      // Recherche du hash et vérification d'expiration
      const result = await fastify.pg.query(
        'SELECT user_id, expires_at FROM refresh_tokens WHERE token_hash = $1',
        [tokenHash]
      );

      if (result.rowCount === 0) {
        return reply.code(401).send({ error: 'Invalid refresh token' });
      }

      const { user_id, expires_at } = result.rows[0];
      if (new Date() > expires_at) {
        // Supprime le token expiré
        await fastify.pg.query(
          'DELETE FROM refresh_tokens WHERE token_hash = $1',
          [tokenHash]
        );
        return reply.code(401).send({ error: 'Refresh token expired' });
      }

      // Génère un nouveau access token
      const accessToken = fastify.jwt.sign(
        { id: user_id },
        { expiresIn: '1h' }
      );

      return reply.send({ accessToken });

    } catch (err) {
      req.log.error(err);
      return reply.code(500).send({ error: 'Server error during token refresh' });
    }
  });
}