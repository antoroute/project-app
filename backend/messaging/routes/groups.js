export function groupRoutes(fastify) {
  const pool = fastify.pg;

  // Créer un groupe
  fastify.post('/groups', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['name', 'publicKeyGroup'],
        properties: {
          name: { type: 'string' },
          publicKeyGroup: { type: 'string', minLength: 800 }
        }
      }
    },
    handler: async (request, reply) => {
      const { name, publicKeyGroup } = request.body;
      const userId = request.user.id;

      try {
        const group = await pool.query(
          'INSERT INTO groups (name) VALUES ($1) RETURNING id',
          [name]
        );

        await pool.query(
          'INSERT INTO user_groups (user_id, group_id, public_key_group) VALUES ($1, $2, $3)',
          [userId, group.rows[0].id, publicKeyGroup]
        );

        return reply.code(201).send({ groupId: group.rows[0].id });
      } catch (err) {
        request.log.error(err);
        return reply.code(400).send({ error: 'Group creation failed' });
      }
    }
  });

  // Rejoindre un groupe existant
  fastify.post('/groups/:id/join', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['publicKeyGroup'],
        properties: {
          publicKeyGroup: { type: 'string', minLength: 700 }
        }
      }
    },
    handler: async (request, reply) => {
      const groupId = request.params.id;
      const userId = request.user.id;
      const { publicKeyGroup } = request.body;

      const exists = await pool.query('SELECT 1 FROM groups WHERE id = $1', [groupId]);
      if (exists.rowCount === 0) {
        return reply.code(404).send({ error: 'Group not found' });
      }

      const existing = await pool.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [userId, groupId]
      );
      if (existing.rowCount > 0) {
        return reply.code(409).send({ error: 'Already joined' });
      }

      try {
        await pool.query(
          'INSERT INTO user_groups (user_id, group_id, public_key_group) VALUES ($1, $2, $3)',
          [userId, groupId, publicKeyGroup]
        );
        return reply.code(201).send({ joined: true });
      } catch (err) {
        request.log.error(err);
        return reply.code(400).send({ error: 'Join failed' });
      }
    }
  });

  // Voir les membres d’un groupe
  fastify.get('/groups/:id/members', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const groupId = request.params.id;
      const userId = request.user.id;

      const isMember = await pool.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [userId, groupId]
      );

      if (isMember.rowCount === 0) {
        return reply.code(403).send({ error: 'Forbidden: not a group member' });
      }

      try {
        const members = await pool.query(`
          SELECT u.id AS "userId", u.email, ug.public_key_group AS "publicKeyGroup"
          FROM user_groups ug
          JOIN users u ON u.id = ug.user_id
          WHERE ug.group_id = $1
        `, [groupId]);

        return reply.send(members.rows);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to fetch members' });
      }
    }
  });
}
