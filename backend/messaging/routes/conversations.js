import { createVerify } from 'crypto';

export function conversationRoutes(fastify) {
  const db = fastify.pg;

  // Créer une conversation (privée ou subset)
  fastify.post('/conversations', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['groupId', 'userIds', 'encryptedSecrets', 'creatorSignature'],
        properties: {
          groupId: { type: 'string', format: 'uuid' },
          userIds: {
            type: 'array',
            items: { type: 'string', format: 'uuid' },
            minItems: 1
          },
          encryptedSecrets: { type: 'object' },
          creatorSignature: { type: 'string' }
        }
      }
    },
    handler: async (request, reply) => {
      const { groupId, userIds, encryptedSecrets, creatorSignature } = request.body;
      const creatorId = request.user.id;

      const isInGroup = await db.query(
        'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
        [creatorId, groupId]
      );
      if (isInGroup.rowCount === 0) {
        return reply.code(403).send({ error: 'You are not in this group' });
      }

      const result = await db.query(
        'SELECT user_id FROM user_groups WHERE group_id = $1 AND user_id = ANY($2)',
        [groupId, userIds]
      );
      if (result.rowCount !== userIds.length) {
        return reply.code(400).send({ error: 'One or more users are not in the group' });
      }

      try {
        const userGroup = await db.query(
          'SELECT public_key_group FROM user_groups WHERE user_id = $1 AND group_id = $2',
          [creatorId, groupId]
        );
        if (userGroup.rowCount === 0 || !userGroup.rows[0].public_key_group) {
          return reply.code(400).send({ error: 'Missing public key for creator in group' });
        }
        const publicKey = userGroup.rows[0].public_key_group;

        const verify = createVerify('SHA256');
        verify.update(Buffer.from(JSON.stringify(encryptedSecrets)));
        verify.end();

        const isValidSignature = verify.verify(publicKey, Buffer.from(creatorSignature, 'base64'));
        if (!isValidSignature) {
          return reply.code(400).send({ error: 'Invalid creatorSignature' });
        }
        if (!encryptedSecrets.hasOwnProperty(creatorId)) {
          return reply.code(400).send({ error: 'Creator must include their own encrypted secret' });
        }

        const type = userIds.length === 1 ? 'private' : 'subset';
        const convo = await db.query(
          'INSERT INTO conversations (group_id, type, creator_id, encrypted_secrets) VALUES ($1, $2, $3, $4) RETURNING id',
          [groupId, type, creatorId, encryptedSecrets]
        );
        const convoId = convo.rows[0].id;

        const allUserIds = [...new Set([...userIds, creatorId])];
        const values = allUserIds.map((_, i) => `($1, $${i + 2})`).join(',');
        await db.query(
          `INSERT INTO conversation_users (conversation_id, user_id) VALUES ${values}`,
          [convoId, ...allUserIds]
        );

        return reply.code(201).send({ conversationId: convoId });
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to create conversation' });
      }
    }
  });

  // Récupérer toutes mes conversations
  fastify.get('/conversations', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const userId = request.user.id;
      try {
        const result = await db.query(`
          SELECT c.id AS "conversationId",
                 c.group_id AS "groupId",
                 c.type,
                 c.creator_id AS "creatorId"
            FROM conversation_users cu
            JOIN conversations c ON c.id = cu.conversation_id
           WHERE cu.user_id = $1
        ORDER BY c.created_at DESC
        `, [userId]);
        return reply.send(result.rows);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to load conversations' });
      }
    }
  });

  // Récupérer les détails d'une conversation
  fastify.get('/conversations/:id', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const conversationId = request.params.id;
      const userId = request.user.id;

      const isInConversation = await db.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, userId]
      );
      if (isInConversation.rowCount === 0) {
        return reply.code(403).send({ error: 'Access denied to this conversation' });
      }

      try {
        const convo = await db.query(
          'SELECT id, group_id, type, creator_id, encrypted_secrets FROM conversations WHERE id = $1',
          [conversationId]
        );
        if (convo.rowCount === 0) {
          return reply.code(404).send({ error: 'Conversation not found' });
        }
        return reply.send(convo.rows[0]);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to fetch conversation' });
      }
    }
  });

  // Voir les messages d'une conversation
  fastify.get('/conversations/:id/messages', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const conversationId = request.params.id;
      const userId = request.user.id;

      const isInConversation = await db.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, userId]
      );
      if (isInConversation.rowCount === 0) {
        return reply.code(403).send({ error: 'Access denied to this conversation' });
      }

      try {
        const res = await db.query(
          `SELECT id,
                  sender_id AS "senderId",
                  encrypted_message,
                  encrypted_keys,
                  created_at,
                  signature_valid
             FROM messages
            WHERE conversation_id = $1
         ORDER BY created_at ASC`,
          [conversationId]
        );

        const messages = res.rows.map(msg => {
          let parsed;
          try {
            parsed = JSON.parse(msg.encrypted_message);
          } catch (err) {
            request.log.warn(`⚠️ Failed to parse encrypted_message for message ${msg.id}`);
            parsed = {};
          }
          return {
            id:            msg.id,
            senderId:      msg.senderId,
            encrypted:     parsed.encrypted     ?? null,
            iv:            parsed.iv            ?? null,
            signature:     parsed.signature     ?? null,
            senderPublicKey: parsed.senderPublicKey ?? null,
            timestamp:     Math.floor(new Date(msg.created_at).getTime() / 1000),
            signatureValid: msg.signature_valid
          };
        });

        return reply.send(messages);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to fetch messages' });
      }
    }
  });

  // ✅ Envoyer un message via fallback REST
  fastify.post('/messages', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['conversationId', 'encrypted_message', 'encrypted_keys'],
        properties: {
          conversationId:    { type: 'string', format: 'uuid' },
          encrypted_message: { type: 'string', minLength: 10 }, // JSON { encrypted, iv, signature, senderPublicKey }
          encrypted_keys:    { type: 'object' }                  // JSON user_id→encrypted AES key
        }
      }
    },
    handler: async (request, reply) => {
      const userId = request.user.id;
      const { conversationId, encrypted_message, encrypted_keys } = request.body;

      // Vérifie l’appartenance à la conversation
      const isInConversation = await db.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, userId]
      );
      if (isInConversation.rowCount === 0) {
        return reply.code(403).send({ error: 'You are not in this conversation' });
      }

      try {
        // Déballer l’envelope JSON
        const envelope = JSON.parse(encrypted_message);
        const { encrypted, iv, signature, senderPublicKey } = envelope;

        // Récupérer la clé publique utilisateur
        const userRes = await db.query(
          'SELECT public_key FROM users WHERE id = $1',
          [userId]
        );
        if (userRes.rowCount === 0 || !userRes.rows[0].public_key) {
          return reply.code(400).send({ error: 'Public key not found for sender' });
        }
        const publicKey = userRes.rows[0].public_key;

        // Vérification de la signature
        const canonicalPayload = JSON.stringify({ encrypted, iv });
        const verify = createVerify('SHA256');
        verify.update(Buffer.from(canonicalPayload));
        verify.end();
        const isValid = verify.verify(publicKey, Buffer.from(signature, 'base64'));

        // Stocker le message
        await db.query(
          `INSERT INTO messages
             (conversation_id, sender_id, encrypted_message, encrypted_keys, signature_valid)
           VALUES ($1, $2, $3, $4, $5)`,
          [conversationId, userId, encrypted_message, encrypted_keys, isValid]
        );

        return reply.code(201).send({ status: 'Message stored', signatureValid: isValid });
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Message not stored' });
      }
    }
  });

  // Récupérer les membres d'une conversation
  fastify.get('/conversations/:id/members', {
    preHandler: fastify.authenticate,
    handler: async (request, reply) => {
      const conversationId = request.params.id;
      const userId = request.user.id;

      const isInConversation = await db.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, userId]
      );
      if (isInConversation.rowCount === 0) {
        return reply.code(403).send({ error: 'Access denied to this conversation' });
      }

      try {
        const members = await db.query(`
          SELECT u.id AS "userId", u.username
            FROM conversation_users cu
            JOIN users u ON u.id = cu.user_id
           WHERE cu.conversation_id = $1
        `, [conversationId]);

        return reply.send(members.rows);
      } catch (err) {
        request.log.error(err);
        return reply.code(500).send({ error: 'Failed to fetch conversation members' });
      }
    }
  });
}