import { createVerify } from 'crypto';

export function groupRoutes(fastify) {
  const pool = fastify.pg;

  // ─── Créer un groupe ─────────────────────────────────────────────────────────
  // On stocke aussi creator_id dans groups, et on insère direct la 1ʳᵉ clé user→groupe
  fastify.post('/groups', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['name', 'publicKeyGroup'],
        properties: {
          name:           { type: 'string' },
          publicKeyGroup: { type: 'string', minLength: 700 }
        }
      }
    }
  }, async (request, reply) => {
    const { name, publicKeyGroup } = request.body;
    const userId = request.user.id;

    try {
      // 1) création du groupe avec creator_id
      const groupRes = await pool.query(
        `INSERT INTO groups (name, creator_id)
         VALUES ($1, $2) RETURNING id`,
        [name, userId]
      );
      const groupId = groupRes.rows[0].id;

      // 2) on inscrit immédiatement le créateur comme membre
      await pool.query(
        `INSERT INTO user_groups (user_id, group_id, public_key_group)
         VALUES ($1, $2, $3)`,
        [userId, groupId, publicKeyGroup]
      );

      return reply.code(201).send({ groupId });
    } catch (err) {
      request.log.error(err);
      return reply.code(400).send({ error: 'Group creation failed' });
    }
  });

  // ─── Voir les détails d’un groupe (nom) ───────────────────────────────────────
  fastify.get('/groups/:id', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const groupId = request.params.id;
      const userId = request.user.id;

      // Seuls les membres peuvent voir
      const isMember = await pool.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [userId, groupId]
      );
      if (isMember.rowCount === 0) {
        return reply.code(403).send({ error: 'Forbidden: not a group member' });
      }

      try {
        const result = await pool.query(
          'SELECT id, name FROM groups WHERE id = $1',
          [groupId]
        );
        if (result.rowCount === 0) {
          return reply.code(404).send({ error: 'Group not found' });
        }
        return reply.send(result.rows[0]);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to fetch group' });
      }
    }
  });

  // ─── Déposer une demande d’adhésion ──────────────────────────────────────────
  fastify.post('/groups/:id/join-request', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['publicKeyGroup'],
        properties: {
          publicKeyGroup: { type: 'string', minLength: 700 }
        }
      }
    }
  }, async (request, reply) => {
    const groupId = request.params.id;
    const userId = request.user.id;
    const { publicKeyGroup } = request.body;

    // Le groupe doit exister
    const grp = await pool.query('SELECT 1 FROM groups WHERE id = $1', [groupId]);
    if (grp.rowCount === 0) {
      return reply.code(404).send({ error: 'Group not found' });
    }

    // Pas déjà membre
    const already = await pool.query(
      'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
      [userId, groupId]
    );
    if (already.rowCount > 0) {
      return reply.code(409).send({ error: 'Already a member' });
    }

    // Pas déjà en attente
    const pending = await pool.query(
      `SELECT 1 FROM join_requests
       WHERE user_id = $1 AND group_id = $2 AND status = 'pending'`,
      [userId, groupId]
    );
    if (pending.rowCount > 0) {
      return reply.code(409).send({ error: 'Join request already pending' });
    }

    try {
      const jr = await pool.query(
        `INSERT INTO join_requests (group_id, user_id, public_key_group)
         VALUES ($1, $2, $3)
         RETURNING id, created_at`,
        [groupId, userId, publicKeyGroup]
      );
      return reply.code(201).send({
        requestId: jr.rows[0].id,
        createdAt: jr.rows[0].created_at
      });
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to create join request' });
    }
  });

  // ─── Lister les demandes en attente ──────────────────────────────────────────
  fastify.get('/groups/:id/join-requests', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const groupId = request.params.id;
      const userId  = request.user.id;

      // Vérifier qu’on est membre pour voter, et que le groupe existe
      const ok = await pool.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [userId, groupId]
      );
      if (ok.rowCount === 0) {
        return reply.code(403).send({ error: 'Forbidden: not a group member' });
      }

      try {
        const res = await pool.query(
          `SELECT
             jr.id,
             jr.user_id   AS "userId",
             u.username,
             jr.created_at,
             jr.public_key_group AS "publicKeyGroup",
             COUNT(*) FILTER (WHERE jrv.vote = TRUE)  AS "yesVotes",
             COUNT(*) FILTER (WHERE jrv.vote = FALSE) AS "noVotes"
           FROM join_requests jr
           JOIN users u ON u.id = jr.user_id
           LEFT JOIN join_request_votes jrv ON jrv.request_id = jr.id
           WHERE jr.group_id = $1 AND jr.status = 'pending'
           GROUP BY jr.id, jr.user_id, u.username, jr.created_at, jr.public_key_group
           ORDER BY jr.created_at ASC`,
          [groupId]
        );
        return reply.send(res.rows);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to list join requests' });
      }
    }
  });

  // ─── Voter POUR/CONTRE une demande ─────────────────────────────────────────
  fastify.post('/groups/:id/join-requests/:reqId/vote', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['vote'],
        properties: {
          vote: { type: 'boolean' }
        }
      }
    }
  }, async (request, reply) => {
    const groupId   = request.params.id;
    const requestId = request.params.reqId;
    const userId    = request.user.id;
    const { vote }  = request.body;

    // Vérifier qu’on est membre du groupe
    const ok = await pool.query(
      'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
      [userId, groupId]
    );
    if (ok.rowCount === 0) {
      return reply.code(403).send({ error: 'Forbidden: not a group member' });
    }

    // Vérifier que la requête existe et appartient bien au groupe
    const jr = await pool.query(
      'SELECT 1 FROM join_requests WHERE id = $1 AND group_id = $2',
      [requestId, groupId]
    );
    if (jr.rowCount === 0) {
      return reply.code(404).send({ error: 'Join request not found' });
    }

    try {
      // Upsert du vote
      await pool.query(
        `INSERT INTO join_request_votes (request_id, voter_id, vote)
         VALUES ($1, $2, $3)
         ON CONFLICT (request_id, voter_id)
         DO UPDATE SET vote = EXCLUDED.vote, created_at = CURRENT_TIMESTAMP`,
        [requestId, userId, vote]
      );

      // Renvoi du décompte mis à jour
      const counts = await pool.query(
        `SELECT
           COUNT(*) FILTER (WHERE vote = TRUE)  AS "yesVotes",
           COUNT(*) FILTER (WHERE vote = FALSE) AS "noVotes"
         FROM join_request_votes
         WHERE request_id = $1`,
        [requestId]
      );
      return reply.send(counts.rows[0]);
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to record vote' });
    }
  });

  // ─── Accepter / Refuser une demande (seul le créateur) ───────────────────────
  fastify.post('/groups/:id/join-requests/:reqId/handle', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['action'],
        properties: {
          action: { type: 'string', enum: ['accept','reject'] }
        }
      }
    }
  }, async (request, reply) => {
    const groupId   = request.params.id;
    const requestId = request.params.reqId;
    const userId    = request.user.id;
    const { action }= request.body;

    // 1) Vérifier que je suis bien le créateur du groupe
    const grp = await pool.query(
      'SELECT creator_id FROM groups WHERE id = $1',
      [groupId]
    );
    if (grp.rowCount === 0) {
      return reply.code(404).send({ error: 'Group not found' });
    }
    if (grp.rows[0].creator_id !== userId) {
      return reply.code(403).send({ error: 'Only the group creator can handle join requests' });
    }

    // 2) Charger la requête
    const jr = await pool.query(
      `SELECT user_id, public_key_group, status
         FROM join_requests
        WHERE id = $1 AND group_id = $2`,
      [requestId, groupId]
    );
    if (jr.rowCount === 0) {
      return reply.code(404).send({ error: 'Join request not found' });
    }
    if (jr.rows[0].status !== 'pending') {
      return reply.code(400).send({ error: 'Join request already handled' });
    }

    try {
      // 3) Mettre à jour le statut
      await pool.query(
        `UPDATE join_requests
            SET status = $1,
                handled_by = $2
          WHERE id = $3`,
        [action === 'accept' ? 'accepted' : 'rejected', userId, requestId]
      );

      // 4) Si accepté → on inscrit définitivement dans user_groups
      if (action === 'accept') {
        const newUserId = jr.rows[0].user_id;
        const publicKey = jr.rows[0].public_key_group;
        await pool.query(
          `INSERT INTO user_groups (user_id, group_id, public_key_group)
           VALUES ($1, $2, $3)`,
          [newUserId, groupId, publicKey]
        );
      }

      return reply.send({ handled: true });
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to handle join request' });
    }
  });

  // ─── Voir les membres d’un groupe ────────────────────────────────────────────
  fastify.get('/groups/:id/members', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const groupId = request.params.id;
      const userId  = request.user.id;

      const isMember = await pool.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [userId, groupId]
      );
      if (isMember.rowCount === 0) {
        return reply.code(403).send({ error: 'Forbidden: not a group member' });
      }

      try {
        const members = await pool.query(`
          SELECT u.id   AS "userId",
                 u.email,
                 u.username,
                 ug.public_key_group AS "publicKeyGroup"
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