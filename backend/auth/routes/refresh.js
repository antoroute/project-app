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
        // Recherche du token et vérification d'expiration
        const result = await fastify.pg.query(
          'SELECT user_id, expires_at FROM refresh_tokens WHERE token = $1',
          [refreshToken]
        );
  
        if (result.rowCount === 0) {
          return reply.code(401).send({ error: 'Invalid refresh token' });
        }
  
        const { user_id, expires_at } = result.rows[0];
        if (new Date() > expires_at) {
          // Supprime le token expiré
          await fastify.pg.query(
            'DELETE FROM refresh_tokens WHERE token = $1',
            [refreshToken]
          );
          return reply.code(401).send({ error: 'Refresh token expired' });
        }
  
        // Génère un nouveau access token
        const token = fastify.jwt.sign(
          { id: user_id },
          { expiresIn: '1h' }
        );
  
        return reply.send({ accessToken: token });
  
      } catch (err) {
        req.log.error(err);
        return reply.code(500).send({ error: 'Server error during token refresh' });
      }
    });
}
  