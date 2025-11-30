// backend/messaging/src/routes/messages.v2.ts
// Envoi + fetch des messages V2 (X25519/Ed25519/AES-GCM)
// Émet "message:new" en WS sur la room conv:<id>.

import { FastifyInstance } from 'fastify';
import { SendMessageV2Schema, SendMessageV2Reply } from '../schemas/messageV2.schema.js';
import { Type } from '@sinclair/typebox';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  // POST /api/messages (V2 only)
  app.post('/api/messages', {
    schema: { body: SendMessageV2Schema, response: { 201: SendMessageV2Reply } }
  }, async (req, reply) => {
    const b = req.body as any;

    // ACL: vérifie appartenance et devices actifs
    const allowed = await app.services.acl.canSend(b.sender.userId, b.sender.deviceId, b.groupId, b.convId, b.recipients);
    if (!allowed) return reply.code(403).send({ error: 'forbidden' });

    try {
      const row = await app.db.one(`
        INSERT INTO messages(
          conversation_id, sender_id, sender_device_id, v, alg,
          message_id, sent_at, sender_eph_pub, iv, ciphertext, wrapped_keys, sig, salt
        )
        VALUES($1,$2,$3,2,$4::jsonb,$5,$6,
               decode($7,'base64'), decode($8,'base64'), decode($9,'base64'), $10::jsonb, decode($11,'base64'), decode($12,'base64'))
        RETURNING id
      `, [
        b.convId, b.sender.userId, b.sender.deviceId,
        JSON.stringify(b.alg),
        b.messageId, new Date(b.sentAt * 1000).toISOString(),
        b.sender.eph_pub, b.iv, b.ciphertext,
        JSON.stringify(b.recipients),
        b.sig,
        b.salt // Ajouter la salt au INSERT
      ]);

      // SÉCURITÉ: Émettre un ping avec convId et groupId (identifiants, pas de contenu sensible)
      // Les clients devront récupérer les messages via l'API après avoir reçu le ping
      // Le convId et groupId sont nécessaires pour identifier quelle conversation a reçu le message
      app.io.to(`conv:${b.convId}`).except(`user:${b.sender.userId}`).emit('message:new', {
        type: 'message:new',
        convId: b.convId,
        groupId: b.groupId,
        // Pas de messageId, pas de contenu, pas de senderId - juste les identifiants nécessaires
      });
      app.log.info({ 
        convId: b.convId, 
        messageId: b.messageId, 
        senderId: b.sender.userId,
        event: 'message_ping_sent'
      }, 'Message ping sent to conversation (excluding sender, no sensitive data)');

      // Hint presence/analytics (option)
      app.log.info({ convId: b.convId, messageId: b.messageId, wraps: b.recipients.length }, 'message stored');
      reply.code(201);
      return { id: row.id };
    } catch (e: any) {
      if (String(e.message).includes('uidx_messages_message_id'))
        return reply.code(409).send({ error: 'duplicate_messageId' });
      throw e;
    }
  });

  // GET /api/conversations/:id/messages : v2 only
  app.get('/api/conversations/:id/messages', {
    schema: {
      params: Type.Object({ id: Type.String({ format: 'uuid' }) }),
      querystring: Type.Object({
        cursor: Type.Optional(Type.String()),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 }))
      })
    }
  }, async (req, reply) => {
    const { id } = req.params as any;
    try {
      const userId = (req.user as any).sub;
      const { cursor, limit = 50 } = req.query as any;

      // ACL: vérifier que l'utilisateur est membre de la conversation
      const membership = await app.db.any(
        `SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2`,
        [id, userId]
      );
      console.log(`📥 GET /conversations/${id}/messages - userId: ${userId}, membership: ${membership.length > 0 ? 'OK' : 'FORBIDDEN'}`);
      
      if (membership.length === 0) {
        return reply.code(403).send({ error: 'forbidden' });
      }

      // CORRECTION: Validation et conversion du cursor
      let cursorDate = null;
      if (cursor) {
        try {
          const cursorMs = Number(cursor);
          if (isNaN(cursorMs) || cursorMs < 0) {
            console.log(`⚠️ Cursor invalide: ${cursor}`);
            return reply.code(400).send({ error: 'invalid_cursor' });
          }
          cursorDate = new Date(cursorMs);
          console.log(`📅 Cursor converti: ${cursor} -> ${cursorDate.toISOString()}`);
        } catch (e) {
          console.log(`❌ Erreur conversion cursor: ${e}`);
          return reply.code(400).send({ error: 'invalid_cursor_format' });
        }
      }

      // CORRECTION: Requête SQL avec validation des paramètres
      const queryParams = [id, cursorDate, limit];
      console.log(`🔍 Paramètres de requête: conversationId=${id}, cursor=${cursorDate}, limit=${limit}`);
      
      const rows = await app.db.any(`
        SELECT m.id, m.conversation_id as "convId",
               encode(m.sender_eph_pub,'base64') as "sender_eph_pub",
               encode(m.iv,'base64') as "iv",
               encode(m.ciphertext,'base64') as "ciphertext",
               m.wrapped_keys as "recipients",
               REPLACE(REPLACE(encode(m.sig,'base64'), '\r', ''), '\n', '') as "sig",
               encode(m.salt,'base64') as "salt",
               m.alg, m.v, m.sender_id as "senderUserId", m.sender_device_id as "senderDeviceId",
               m.message_id as "messageId", extract(epoch from m.sent_at)::bigint as "sentAt",
               c.group_id as "groupId"
          FROM messages m
          JOIN conversations c ON c.id = m.conversation_id
         WHERE m.conversation_id = $1
           AND ($2::timestamp IS NULL OR m.sent_at < $2)
         ORDER BY m.sent_at DESC
         LIMIT $3
      `, queryParams);
      console.log(`📥 Messages found for conversation ${id}: ${rows.length} messages`);
      console.log(`📅 Cursor utilisé: ${cursorDate ? cursorDate.toISOString() : 'null'}`);
      console.log(`📊 Limit utilisé: ${limit}`);
      
      // CORRECTION: nextCursor doit être le timestamp du message le plus ancien de cette page
      const nextCursor = rows.length > 0 ? rows[rows.length - 1].sentAt : null;
      console.log(`📄 Next cursor: ${nextCursor}`);
      
      return { items: rows, nextCursor };
    } catch (e: any) {
      console.error(`❌ Erreur GET /conversations/${id}/messages:`, e);
      return reply.code(500).send({ error: 'internal_server_error', details: e.message });
    }
  });
}
