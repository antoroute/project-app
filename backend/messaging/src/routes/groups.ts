// backend/messaging/src/routes/groups.ts
// Groupes : créer, lister, join requests (v2 inclut deviceId + clés publiques), accepter/rejeter.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

import type { DbExecutor } from '../plugins/db.js';
import { authenticatedUserId } from '../security/jwt.js';
import { groupRoleAllows } from '../services/acl.js';

type JoinRequestResult =
  | { outcome: 'created'; requestId: string }
  | { outcome: 'already_member' | 'already_pending' | 'forbidden' };

type JoinDecisionResult =
  | { outcome: 'handled'; joinedUserId: string | null }
  | { outcome: 'forbidden' };

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  async function lockGroup(
    transaction: DbExecutor,
    groupId: string,
  ): Promise<boolean> {
    return (await transaction.oneOrNone(
      `SELECT id FROM groups WHERE id = $1 FOR UPDATE`,
      [groupId],
    )) !== null;
  }

  async function createJoinRequest(
    userId: string,
    groupId: string,
    deviceId: string,
    signatureKey: string | null,
    kemKey: string | null,
  ): Promise<JoinRequestResult> {
    return app.db.transaction(async (transaction: DbExecutor) => {
      if (!(await lockGroup(transaction, groupId))) {
        return { outcome: 'forbidden' };
      }

      const membership = await transaction.oneOrNone(
        `SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2`,
        [userId, groupId],
      );
      if (membership) return { outcome: 'already_member' };

      const pending = await transaction.oneOrNone(
        `SELECT 1
           FROM join_requests
          WHERE user_id = $1 AND group_id = $2 AND status = 'pending'`,
        [userId, groupId],
      );
      if (pending) return { outcome: 'already_pending' };

      const request = signatureKey !== null && kemKey !== null
        ? await transaction.one(
          `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
           VALUES($1,$2,$3,decode($4,'base64'),decode($5,'base64'))
           RETURNING id`,
          [groupId, userId, deviceId, signatureKey, kemKey],
        )
        : await transaction.one(
          `INSERT INTO join_requests(group_id, user_id, device_id, pk_sig, pk_kem)
           VALUES($1,$2,$3,E'\\x0000000000000000000000000000000000000000000000000000000000000000',E'\\x0000000000000000000000000000000000000000000000000000000000000000')
           RETURNING id`,
          [groupId, userId, deviceId],
        );

      return { outcome: 'created', requestId: request.id };
    });
  }

  async function handleJoinRequest(
    approverId: string,
    groupId: string,
    requestId: string,
    action: 'accept' | 'reject',
  ): Promise<JoinDecisionResult> {
    return app.db.transaction(async (transaction: DbExecutor) => {
      if (!(await lockGroup(transaction, groupId))) {
        return { outcome: 'forbidden' };
      }
      if (!(await app.services.acl.hasGroupPermission(
        approverId,
        groupId,
        'join-request:handle',
        { executor: transaction, lock: true },
      ))) {
        return { outcome: 'forbidden' };
      }

      const request = await transaction.oneOrNone(
        `SELECT id, user_id, device_id, pk_sig, pk_kem
           FROM join_requests
          WHERE id = $1 AND group_id = $2 AND status = 'pending'
          FOR UPDATE`,
        [requestId, groupId],
      );
      if (!request) return { outcome: 'forbidden' };

      if (action === 'reject') {
        await transaction.none(
          `UPDATE join_requests
              SET status = 'rejected', handled_by = $1
            WHERE id = $2`,
          [approverId, requestId],
        );
        return { outcome: 'handled', joinedUserId: null };
      }

      await transaction.none(
        `INSERT INTO user_groups(user_id, group_id)
         VALUES($1,$2)
         ON CONFLICT DO NOTHING`,
        [request.user_id, groupId],
      );
      if (
        request.pk_sig && request.pk_kem && request.device_id &&
        request.pk_sig.length > 0 && request.pk_kem.length > 0
      ) {
        await transaction.none(
          `INSERT INTO group_device_keys(
             group_id, user_id, device_id, pk_sig, pk_kem, key_version, status
           )
           VALUES($1,$2,$3,$4,$5,1,'active')
           ON CONFLICT (group_id,user_id,device_id) DO NOTHING`,
          [
            groupId,
            request.user_id,
            request.device_id,
            request.pk_sig,
            request.pk_kem,
          ],
        );
      }
      await transaction.none(
        `UPDATE join_requests
            SET status = 'accepted', handled_by = $1
          WHERE id = $2`,
        [approverId, requestId],
      );
      return { outcome: 'handled', joinedUserId: request.user_id };
    });
  }

  function announceAcceptedMember(
    groupId: string,
    joinedUserId: string,
    approverId: string,
  ) {
    app.io.in(`user:${joinedUserId}`).socketsJoin(`group:${groupId}`);
    app.io.to(`group:${groupId}`).emit('group:member_joined', {
      type: 'group:member_joined',
      groupId,
    });
    app.io.to(`user:${joinedUserId}`).emit('group:joined', {
      type: 'group:joined',
      groupId,
    });
    if (app.services.presence?.broadcastUserPresence) {
      app.services.presence.broadcastUserPresence(joinedUserId, true, 1);
    }
    app.log.info(
      { groupId, userId: joinedUserId, approverId },
      'Join request committed and minimal notifications emitted',
    );
  }

  // POST /api/groups  { name, groupSigningPubKey, groupKEMPubKey }
  app.post('/api/groups', {
    schema: { 
      body: Type.Object({ 
        name: Type.String({ minLength: 3, maxLength: 64 }),
        groupSigningPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        groupKEMPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' }))
      }) 
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { name, groupSigningPubKey, groupKEMPubKey } = req.body as any;

    const g = await app.db.transaction(async (transaction: DbExecutor) => {
      const createdGroup = await transaction.one(
        `INSERT INTO groups(name, creator_id) VALUES($1,$2) RETURNING id`,
        [name, userId],
      );
      if (groupSigningPubKey) {
        await transaction.none(
          `INSERT INTO group_keys(group_id, pk_sig, key_version)
           VALUES($1,decode($2,'base64'),1)`,
          [createdGroup.id, groupSigningPubKey],
        );
      }
      await transaction.none(
        `INSERT INTO user_groups(user_id, group_id) VALUES($1,$2)`,
        [userId, createdGroup.id],
      );
      return createdGroup;
    });

    // CORRECTION: S'assurer que le créateur est dans la room AVANT d'émettre l'événement
    // Rejoindre le créateur à la room du groupe
    app.io.in(`user:${userId}`).socketsJoin(`group:${g.id}`);
    app.log.info({ groupId: g.id, userId }, 'Creator joined group room');

    // SÉCURITÉ: Émettre uniquement un ping minimal (pas de données sensibles)
    // Le créateur n'a pas besoin de notification car il vient de créer le groupe
    // Les autres utilisateurs recevront la notification quand ils rejoindront le groupe
    // Note: On n'émet rien ici car le créateur est déjà au courant
    app.log.info({ groupId: g.id, userId }, 'Group created (no notification needed for creator)');

    reply.code(201); // Explicitement retourner le code 201 Created
    return { groupId: g.id, name };
  });

  // GET /api/groups  : groupes dont je suis membre
  app.get('/api/groups', async (req, reply) => {
    const userId = authenticatedUserId(req);
    const rows = await app.db.any(
      `SELECT g.id, g.name, g.creator_id AS "creatorId",
              CASE WHEN g.creator_id = $1 THEN 'owner' ELSE ug.role END AS role,
              g.created_at as "createdAt"
         FROM groups g
         JOIN user_groups ug ON ug.group_id=g.id
        WHERE ug.user_id=$1
        ORDER BY g.created_at DESC`,
      [userId]
    );
    return rows;
  });

  // GET /api/groups/:id : détails d'un groupe spécifique
  app.get('/api/groups/:id', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    const role = await app.services.acl.getGroupRole(userId, groupId);
    if (role === null || !groupRoleAllows(role, 'group:read')) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Récupère les détails du groupe
    const groups = await app.db.any(
      `SELECT g.id, g.name, g.creator_id, g.created_at
        FROM groups g WHERE g.id=$1`,
      [groupId]
    );

    if (groups.length === 0) {
      return reply.code(404).send({ error: 'group_not_found' });
    }

    const group = groups[0];

    return {
      id: group.id,
      name: group.name,
      creatorId: group.creator_id,
      role,
      createdAt: group.created_at.toISOString()
    };
  });

  // GET /api/groups/:id/members : membres d'un groupe
  app.get('/api/groups/:id/members', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    if (!(await app.services.acl.hasGroupPermission(
      userId,
      groupId,
      'members:read',
    ))) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Récupère les membres du groupe
    const members = await app.db.any(
      `SELECT u.id, u.email, u.username, u.created_at,
              CASE WHEN g.creator_id = u.id THEN 'owner' ELSE ug.role END AS role
        FROM users u
        JOIN user_groups ug ON ug.user_id = u.id
        JOIN groups g ON g.id = ug.group_id
        WHERE ug.group_id = $1
        ORDER BY u.username`,
      [groupId]
    );

    return members.map((member: any) => ({
      userId: member.id,
      email: member.email,
      username: member.username,
      role: member.role,
      joinedAt: member.created_at.toISOString()
    }));
  });

  // POST /api/groups/:id/join  { deviceId, pk_sig, pk_kem, groupSigningPubKey, groupKEMPubKey }
  // Crée une join_request (v2) incluant les clés de l'appareil initial et du groupe
  app.post('/api/groups/:id/join', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        deviceId: Type.String({ minLength: 1, maxLength: 128 }),
        pk_sig: Type.String({ contentEncoding: 'base64' }),
        pk_kem: Type.String({ contentEncoding: 'base64' }),
        groupSigningPubKey: Type.String({ contentEncoding: 'base64' }),
        groupKEMPubKey: Type.String({ contentEncoding: 'base64' })
      })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;
    const { deviceId, pk_sig, pk_kem } = req.body as any;
    const result = await createJoinRequest(
      userId,
      groupId,
      deviceId,
      pk_sig,
      pk_kem,
    );
    if (result.outcome === 'forbidden') {
      return reply.code(403).send({ error: 'forbidden' });
    }
    if (result.outcome !== 'created') {
      return reply.code(409).send({ error: result.outcome });
    }
    return { id: result.requestId, status: 'pending' };
  });

  // POST /api/groups/:id/requests/:rid/accept
  // Route legacy conservée pour compatibilité client.
  app.post('/api/groups/:id/requests/:rid/accept', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, rid } = req.params as any;

    const result = await handleJoinRequest(
      approverId,
      groupId,
      rid,
      'accept',
    );
    if (result.outcome === 'forbidden') {
      return reply.code(403).send({ error: 'forbidden' });
    }
    if (result.joinedUserId) {
      announceAcceptedMember(groupId, result.joinedUserId, approverId);
    }

    return { ok: true };
  });

  // POST /api/groups/:id/join-requests { groupSigningPubKey, groupKEMPubKey }
  // Crée une demande de jointure avec les clés du groupe  
  app.post('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      body: Type.Object({
        groupSigningPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        groupKEMPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        deviceId: Type.Optional(Type.String()),
        deviceSigPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' })),
        deviceKemPubKey: Type.Optional(Type.String({ contentEncoding: 'base64' }))
      })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;
    const { deviceId, deviceSigPubKey, deviceKemPubKey } = req.body as any;
    const hasDeviceKeys = Boolean(
      deviceId && deviceSigPubKey && deviceKemPubKey,
    );
    const result = await createJoinRequest(
      userId,
      groupId,
      deviceId || '',
      hasDeviceKeys ? deviceSigPubKey : null,
      hasDeviceKeys ? deviceKemPubKey : null,
    );
    if (result.outcome === 'forbidden') {
      return reply.code(403).send({ error: 'forbidden' });
    }
    if (result.outcome !== 'created') {
      return reply.code(409).send({ error: result.outcome });
    }

    reply.code(201); // Explicitement retourner le code 201 Created
    return { requestId: result.requestId, status: 'pending' };
  });

  // GET /api/groups/:id/join-requests
  // Récupère les demandes de jointure pour les gestionnaires du cercle.
  app.get('/api/groups/:id/join-requests', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: groupId } = req.params as any;

    if (!(await app.services.acl.hasGroupPermission(
      userId,
      groupId,
      'join-request:read',
    ))) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    const rows = await app.db.any(
      `SELECT jr.id, jr.user_id, jr.device_id, jr.status, jr.created_at,
              u.email, u.username
         FROM join_requests jr
         JOIN users u ON u.id = jr.user_id
        WHERE jr.group_id = $1 AND jr.status = 'pending'
        ORDER BY jr.created_at DESC`,
      [groupId]
    );
    
    return rows.map((row: { id: any; user_id: any; device_id: any; status: any; created_at: { toISOString: () => any; }; email: any; username: any; }) => ({
      id: row.id,
      userId: row.user_id,
      deviceId: row.device_id,
      status: row.status,
      createdAt: row.created_at.toISOString(),
      email: row.email,
      username: row.username
    }));
  });

  // POST /api/groups/:id/join-requests/:reqId/vote
  // Route héritée neutralisée : la V1 n'utilise aucun vote collectif.
  app.post('/api/groups/:id/join-requests/:reqId/vote', {
    schema: {
      params: Type.Object({ 
        id: Type.String({ format: 'uuid' }),
        reqId: Type.String({ format: 'uuid' })
      }),
      body: Type.Object({
        vote: Type.Boolean()
      })
    }
  }, async (req, reply) => {
    authenticatedUserId(req);
    return reply.code(403).send({ error: 'forbidden' });
  });

  // POST /api/groups/:id/join-requests/:reqId/handle
  // Route pour accepter/rejeter une demande de jointure (owner/admin).
  app.post('/api/groups/:id/join-requests/:reqId/handle', {
    schema: {
      params: Type.Object({ 
        id: Type.String({ format: 'uuid' }),
        reqId: Type.String({ format: 'uuid' })
      }),
      body: Type.Object({
        action: Type.String({ enum: ['accept', 'reject'] })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, reqId } = req.params as any;
    const { action } = req.body as any;

    const result = await handleJoinRequest(
      approverId,
      groupId,
      reqId,
      action,
    );
    if (result.outcome === 'forbidden') {
      return reply.code(403).send({ error: 'forbidden' });
    }
    if (result.joinedUserId) {
      announceAcceptedMember(groupId, result.joinedUserId, approverId);
    }

    reply.code(200); // Explicitement retourner le code 200 OK
    return { ok: true };
  });

  // POST /api/groups/:id/requests/:rid/reject
  // Route legacy conservée pour compatibilité client.
  app.post('/api/groups/:id/requests/:rid/reject', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        rid: Type.String({ format: 'uuid' })
      })
    }
  }, async (req, reply) => {
    const approverId = authenticatedUserId(req);
    const { id: groupId, rid } = req.params as any;

    const result = await handleJoinRequest(
      approverId,
      groupId,
      rid,
      'reject',
    );
    if (result.outcome === 'forbidden') {
      return reply.code(403).send({ error: 'forbidden' });
    }
    return { ok: true };
  });

  // PATCH /api/groups/:id/members/:memberId/role
  // Le propriétaire peut promouvoir/rétrograder un membre sans modifier
  // la propriété, qui reste exclusivement portée par groups.creator_id.
  app.patch('/api/groups/:id/members/:memberId/role', {
    schema: {
      params: Type.Object({
        id: Type.String({ format: 'uuid' }),
        memberId: Type.String({ format: 'uuid' }),
      }),
      body: Type.Object({
        role: Type.Union([Type.Literal('admin'), Type.Literal('member')]),
      }),
    },
  }, async (req, reply) => {
    const ownerId = authenticatedUserId(req);
    const { id: groupId, memberId } = req.params as any;
    const { role } = req.body as any;

    const updated = await app.db.transaction(
      async (transaction: DbExecutor) => {
        if (!(await app.services.acl.hasGroupPermission(
          ownerId,
          groupId,
          'member-role:set',
          { executor: transaction, lock: true },
        ))) {
          return null;
        }
        return transaction.oneOrNone(
          `UPDATE user_groups ug
              SET role = $1
             FROM groups g
            WHERE ug.group_id = $2
              AND ug.user_id = $3
              AND g.id = ug.group_id
              AND g.creator_id = $4
              AND ug.user_id <> g.creator_id
            RETURNING ug.user_id AS "userId", ug.role`,
          [role, groupId, memberId, ownerId],
        );
      },
    );
    if (!updated) return reply.code(403).send({ error: 'forbidden' });

    return updated;
  });
}
