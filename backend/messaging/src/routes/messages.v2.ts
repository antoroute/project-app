// backend/messaging/src/routes/messages.v2.ts
// Envoi + fetch des messages V2 (X25519/Ed25519/AES-GCM)
// Émet "message:new" en WS sur la room conv:<id>.

import { FastifyInstance } from 'fastify';
import { SendMessageV2Schema, SendMessageV2Reply } from '../schemas/messageV2.schema.js';
import { Type } from '@sinclair/typebox';

import type { DbExecutor } from '../plugins/db.js';
import { authenticatedUserId } from '../security/jwt.js';
import { authenticatedDevice } from '../middlewares/deviceAuth.js';
import {
  MAX_MESSAGE_CIPHERTEXT_BYTES,
  Uuid,
  strictObject,
} from '../schemas/input.schema.js';

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);
  app.addHook('preHandler', app.requireActiveDevice);

  // POST /api/messages (V2 only)
  app.post('/api/messages', {
    schema: { body: SendMessageV2Schema, response: { 201: SendMessageV2Reply } }
  }, async (req, reply) => {
    const b = req.body as any;
    const senderUserId = authenticatedUserId(req);
    const requestDevice = authenticatedDevice(req);
    if (Buffer.from(b.ciphertext, 'base64').length > MAX_MESSAGE_CIPHERTEXT_BYTES) {
      return reply.code(400).send({ error: 'ciphertext_too_large' });
    }
    const recipientIds = new Set(
      b.recipients.map(
        (recipient: { userId: string; deviceId: string }) =>
          `${recipient.userId}\u0000${recipient.deviceId}`,
      ),
    );
    if (recipientIds.size !== b.recipients.length) {
      return reply.code(400).send({ error: 'duplicate_recipient' });
    }

    // sender.userId appartient au domaine signé E2EE : une divergence ne peut
    // pas être corrigée silencieusement sans invalider l'enveloppe.
    if (
      b.sender.userId !== senderUserId ||
      b.sender.deviceId !== requestDevice.deviceId
    ) {
      return reply.code(403).send({ error: 'forbidden' });
    }

    try {
      const row = await app.db.transaction(
        async (transaction: DbExecutor) => {
          const allowed = await app.services.acl.canSend(
            senderUserId,
            b.sender.deviceId,
            b.sender.key_version,
            b.groupId,
            b.convId,
            b.recipients,
            { executor: transaction, lock: true },
          );
          if (!allowed) return null;

          return transaction.one(`
            INSERT INTO messages(
              conversation_id, sender_id, sender_device_id, v, alg,
              message_id, sent_at, sender_eph_pub, iv, ciphertext, wrapped_keys, sig, salt
            )
            VALUES($1,$2,$3,2,$4::jsonb,$5,$6,
                   decode($7,'base64'), decode($8,'base64'), decode($9,'base64'), $10::jsonb, decode($11,'base64'), decode($12,'base64'))
            RETURNING id
          `, [
            b.convId, senderUserId, b.sender.deviceId,
            JSON.stringify(b.alg),
            b.messageId, new Date(b.sentAt * 1000).toISOString(),
            b.sender.eph_pub, b.iv, b.ciphertext,
            JSON.stringify(b.recipients),
            b.sig,
            b.salt,
          ]);
        },
      );
      if (!row) return reply.code(403).send({ error: 'forbidden' });

      // SÉCURITÉ: Émettre un ping avec convId et groupId (identifiants, pas de contenu sensible)
      // Les clients devront récupérer les messages via l'API après avoir reçu le ping
      // Le convId et groupId sont nécessaires pour identifier quelle conversation a reçu le message
      app.io.to(`conv:${b.convId}`).except(`user:${senderUserId}`).emit('message:new', {
        type: 'message:new',
        convId: b.convId,
        groupId: b.groupId,
        // Pas de messageId, pas de contenu, pas de senderId - juste les identifiants nécessaires
      });
      app.log.info({ 
        convId: b.convId, 
        messageId: b.messageId, 
        senderId: senderUserId,
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
      params: strictObject({ id: Uuid }),
      querystring: strictObject({
        cursor: Type.Optional(
          Type.String({ minLength: 1, maxLength: 10, pattern: '^[0-9]+$' }),
        ),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100 })),
      }),
    }
  }, async (req, reply) => {
    const { id } = req.params as any;
    try {
      const userId = authenticatedUserId(req);
      const { cursor, limit = 50 } = req.query as any;

      if (!(await app.services.acl.hasConversationPermission(
        userId,
        id,
        'message:read',
      ))) {
        return reply.code(403).send({ error: 'forbidden' });
      }

      // CORRECTION: Validation et conversion du cursor
      let cursorDate = null;
      if (cursor) {
        try {
          const cursorSeconds = Number(cursor);
          if (!Number.isSafeInteger(cursorSeconds) || cursorSeconds < 0) {
            return reply.code(400).send({ error: 'invalid_cursor' });
          }
          cursorDate = new Date(cursorSeconds * 1000);
        } catch (e) {
          return reply.code(400).send({ error: 'invalid_cursor_format' });
        }
      }

      const queryParams = [id, cursorDate, limit];
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

      // CORRECTION: nextCursor doit être le timestamp du message le plus ancien de cette page
      const nextCursor = rows.length > 0 ? rows[rows.length - 1].sentAt : null;
      return { items: rows, nextCursor };
    } catch (e: any) {
      req.log.error({ err: e, conversationId: id }, 'Unable to fetch messages');
      return reply.code(500).send({ error: 'internal_server_error' });
    }
  });
}
