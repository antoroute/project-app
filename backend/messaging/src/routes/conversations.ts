// backend/messaging/src/routes/conversations.ts
// Conversations : créer, lister, marquer comme lu (read receipts), lister les lecteurs.

import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  // POST /api/conversations  { groupId, type: 'private'|'subset', memberIds: UUID[] }
  app.post('/api/conversations', {
    schema: {
      body: Type.Object({
        groupId: Type.String({ format: 'uuid' }),
        type: Type.Union([Type.Literal('private'), Type.Literal('subset')]),
        memberIds: Type.Array(Type.String({ format: 'uuid' }), { minItems: 1 })
      })
    }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { groupId, type, memberIds } = req.body as any;

    const conv = await app.db.one(
      `INSERT INTO conversations(group_id, type, creator_id)
       VALUES($1,$2,$3) RETURNING id`,
      [groupId, type, userId]
    );
    // Ajout des membres (y compris le créateur)
    const allMembers = Array.from(new Set([userId, ...memberIds]));
    for (const uid of allMembers) {
      await app.db.none(
        `INSERT INTO conversation_users(conversation_id, user_id) VALUES($1,$2)
         ON CONFLICT DO NOTHING`,
        [conv.id, uid]
      );
    }

    // Émettre un événement WebSocket pour la création de la conversation
    app.io.emit('conversation:created', { convId: conv.id, groupId, creatorId: userId });
    app.log.info({ convId: conv.id, groupId, userId }, 'Conversation created and broadcasted');

    return { id: conv.id };
  });

  // GET /api/conversations : liste de l'utilisateur
  app.get('/api/conversations', async (req, reply) => {
    const userId = (req.user as any).sub;
    const rows = await app.db.any(
      `SELECT c.id, c.group_id as "groupId", c.type, c.creator_id as "creatorId", c.created_at as "createdAt"
         FROM conversations c
         JOIN conversation_users cu ON cu.conversation_id=c.id
        WHERE cu.user_id=$1
        ORDER BY c.created_at DESC`,
      [userId]
    );
    return rows;
  });

  // GET /api/conversations/:id : détails d'une conversation spécifique
  app.get('/api/conversations/:id', {
    schema: { params: Type.Object({ id: Type.String({ format: 'uuid' }) }) }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: convId } = req.params as any;

    // ACL: être membre de la conversation
    const membership = await app.db.any(
      `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
      [convId, userId]
    );
    if (membership.length === 0) {
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
    schema: { params: Type.Object({ id: Type.String({ format: 'uuid' }) }) }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: convId } = req.params as any;

    // ACL implicite: être membre
    const rows = await app.db.any(
      `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
      [convId, userId]
    );
    if (rows.length === 0) return reply.code(403).send({ error: 'forbidden' });

    const ts = await app.services.acl.markConversationRead(convId, userId);

    // Notifie les autres membres
    app.io.to(`conv:${convId}`).emit('conv:read', { convId, userId, at: ts });

    return { ok: true, at: ts };
  });

  // GET /api/conversations/:id/readers -> qui a lu (last_read_at par membre)
  app.get('/api/conversations/:id/readers', {
    schema: { params: Type.Object({ id: Type.String({ format: 'uuid' }) }) }
  }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const { id: convId } = req.params as any;

    // ACL: membre
    const rows = await app.db.any(
      `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
      [convId, userId]
    );
    if (rows.length === 0) return reply.code(403).send({ error: 'forbidden' });

    const readers = await app.services.acl.listReaders(convId);
    return { readers };
  });

}
