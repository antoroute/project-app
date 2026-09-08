// backend/messaging/src/routes/conversations.ts
// Conversations : créer, lister, marquer comme lu (read receipts), lister les lecteurs.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

import type { DbExecutor } from '../plugins/db.js';
import { authenticatedUserId } from '../security/jwt.js';
import {
  MAX_CONVERSATION_MEMBERS,
  Uuid,
  strictObject,
} from '../schemas/input.schema.js';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);
  app.addHook('preHandler', app.requireActiveDevice);

  // POST /api/conversations  { groupId, type: 'private'|'subset', memberIds: UUID[] }
  app.post('/api/conversations', {
    schema: {
      body: strictObject({
        groupId: Uuid,
        type: Type.Union([Type.Literal('private'), Type.Literal('subset')]),
        memberIds: Type.Array(Uuid, {
          minItems: 1,
          // Le créateur est ajouté automatiquement par la route.
          maxItems: MAX_CONVERSATION_MEMBERS - 1,
          uniqueItems: true,
        }),
      })
    }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { groupId, type, memberIds } = req.body as any;

    const allMembers = [...new Set([userId, ...memberIds])].sort();
    const conv = await app.db.transaction(
      async (transaction: DbExecutor) => {
        const allowed = await app.services.acl.canCreateConversation(
          userId,
          groupId,
          memberIds,
          { executor: transaction, lock: true },
        );
        if (!allowed) return null;

        const createdConversation = await transaction.one(
          `INSERT INTO conversations(group_id, type, creator_id)
           VALUES($1,$2,$3) RETURNING id`,
          [groupId, type, userId],
        );
        await transaction.none(
          `INSERT INTO conversation_users(conversation_id, user_id)
           SELECT $1, members.user_id
             FROM unnest($2::uuid[]) AS members(user_id)`,
          [createdConversation.id, allMembers],
        );
        return createdConversation;
      },
    );
    if (!conv) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Tous les membres ont été validés par l'ACL avant l'insertion.
    for (const uid of allMembers) {
      app.io.in(`user:${uid}`).socketsJoin(`group:${groupId}`);
      app.log.debug({ groupId, userId: uid }, 'User joined group room for conversation creation');
    }
    app.log.info({ groupId, memberCount: allMembers.length }, 'All conversation members joined group room');

    // SÉCURITÉ: Émettre un ping avec convId et groupId (identifiants, pas de données sensibles)
    // Les clients devront récupérer les conversations via l'API après avoir reçu le ping
    // Le convId et groupId sont nécessaires pour identifier quelle conversation a été créée
    // CORRECTION: Exclure le créateur de la notification (il vient de créer la conversation)
    app.log.info({ convId: conv.id, groupId, userId, memberCount: allMembers.length }, 'About to emit conversation:created ping');
    app.io.to(`group:${groupId}`).except(`user:${userId}`).emit('conversation:created', {
      type: 'conversation:created',
      convId: conv.id,
      groupId: groupId,
      // Pas de creatorId, pas de contenu - juste les identifiants nécessaires
    });
    app.log.info({ convId: conv.id, groupId, userId }, 'Conversation created ping sent to group members (excluding creator, no sensitive data)');

    reply.code(201);
    return { id: conv.id };
  });

  // GET /api/conversations : liste de l'utilisateur
  app.get('/api/conversations', async (req, reply) => {
    const userId = authenticatedUserId(req);
    const rows = await app.db.any(
      `SELECT c.id, c.group_id as "groupId", c.type, c.creator_id as "creatorId", c.created_at as "createdAt"
         FROM conversations c
         JOIN conversation_users cu ON cu.conversation_id=c.id
         JOIN user_groups ug ON ug.group_id=c.group_id AND ug.user_id=cu.user_id
        WHERE cu.user_id=$1
        ORDER BY c.created_at DESC`,
      [userId]
    );
    return rows;
  });

  // GET /api/conversations/:id : détails d'une conversation spécifique
  app.get('/api/conversations/:id', {
    schema: { params: strictObject({ id: Uuid }) }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: convId } = req.params as any;

    if (!(await app.services.acl.hasConversationPermission(
      userId,
      convId,
      'conversation:read',
    ))) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Récupérer les détails de la conversation
    const convs = await app.db.any(
      `SELECT c.id, c.group_id as "groupId", c.type, c.creator_id as "creatorId", 
              c.created_at as "createdAt", c.encrypted_secrets as "encryptedSecrets"
         FROM conversations c 
        WHERE c.id=$1`,
      [convId]
    );
    
    if (convs.length === 0) {
      return reply.code(404).send({ error: 'conversation_not_found' });
    }

    const conv = convs[0];
    
    // Récupérer la liste des membres de la conversation
    const members = await app.db.any(
      `SELECT cu.user_id as "userId", u.email, u.username, cu.last_read_at as "lastReadAt"
         FROM conversation_users cu
         JOIN users u ON u.id = cu.user_id
        WHERE cu.conversation_id = $1
        ORDER BY u.email`,
      [convId]
    );

    return {
      ...conv,
      members: members.map((member: any) => ({
        userId: member.userId,
        email: member.email,
        username: member.username,
        lastReadAt: member.lastReadAt ? member.lastReadAt.toISOString() : null
      }))
    };
  });

  // POST /api/conversations/:id/read  -> mark as read + WS "conv:read"
  app.post('/api/conversations/:id/read', {
    schema: { params: strictObject({ id: Uuid }) }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: convId } = req.params as any;

    const ts = await app.db.transaction(
      async (transaction: DbExecutor) => {
        return app.services.acl.markConversationRead(
          convId,
          userId,
          transaction,
        );
      },
    );
    if (ts === null) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    // Notifie les autres membres de la conversation (exclure l'utilisateur qui a marqué comme lu)
    app.io.to(`conv:${convId}`).except(`user:${userId}`).emit('conv:read', { convId, userId, at: ts });
    app.log.info({ convId, userId, at: ts }, 'Read receipt broadcasted to conversation members (excluding reader)');

    return { ok: true, at: ts };
  });

  // GET /api/conversations/:id/readers -> qui a lu (last_read_at par membre)
  app.get('/api/conversations/:id/readers', {
    schema: { params: strictObject({ id: Uuid }) }
  }, async (req, reply) => {
    const userId = authenticatedUserId(req);
    const { id: convId } = req.params as any;

    if (!(await app.services.acl.hasConversationPermission(
      userId,
      convId,
      'readers:read',
    ))) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    const readers = await app.services.acl.listReaders(convId);
    return { readers };
  });

}
