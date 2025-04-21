export function conversationRoutes(fastify) {
    const db = fastify.pg;

    // Créer une conversation (privée ou subset)
    fastify.post('/conversations', {
      preHandler: fastify.authenticate,
      schema: {
        body: {
          type: 'object',
          required: ['groupId', 'userIds'],
          properties: {
            groupId: { type: 'string', format: 'uuid' },
            userIds: {
              type: 'array',
              items: { type: 'string', format: 'uuid' },
              minItems: 1
            }
          }
        }
      },
      handler: async (request, reply) => {
        const { groupId, userIds } = request.body;
        const creatorId = request.user.id;
  
        // Vérifie que l'utilisateur courant appartient au groupe
        const isInGroup = await db.query(
          'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
          [creatorId, groupId]
        );
        if (isInGroup.rowCount === 0) {
          return reply.code(403).send({ error: 'You are not in this group' });
        }
  
        // Vérifie que TOUS les destinataires sont aussi dans le même groupe
        const result = await db.query(
          'SELECT user_id FROM user_groups WHERE group_id = $1 AND user_id = ANY($2)',
          [groupId, userIds]
        );
  
        if (result.rowCount !== userIds.length) {
          return reply.code(400).send({ error: 'One or more users are not in the group' });
        }
  
        try {
          const type = userIds.length === 1 ? 'private' : 'subset';
  
          const convo = await db.query(
            'INSERT INTO conversations (group_id, type, creator_id) VALUES ($1, $2, $3) RETURNING id',
            [groupId, type, creatorId]
          );
          const convoId = convo.rows[0].id;
  
          // Insertion des participants + creator
          const allUserIds = [...new Set([...userIds, creatorId])];
          const values = allUserIds.map((uid, i) => `($1, $${i + 2})`).join(',');
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
            SELECT c.id AS "conversationId", c.group_id AS "groupId", c.type, c.creator_id AS "creatorId"
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
            const messages = await db.query(
            'SELECT id, sender_id AS "senderId", encrypted_message AS "encryptedMessage", encrypted_keys AS "encryptedKeys", created_at FROM messages WHERE conversation_id = $1 ORDER BY created_at ASC',
            [conversationId]
            );

            return reply.send(messages.rows);
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
            required: ['conversationId', 'encryptedMessage', 'encryptedKeys'],
            properties: {
            conversationId: { type: 'string', format: 'uuid' },
            encryptedMessage: { type: 'string', minLength: 10 },
            encryptedKeys: { type: 'object' } // user_id => encrypted AES key
            }
        }
        },
        handler: async (request, reply) => {
        const userId = request.user.id;
        const { conversationId, encryptedMessage, encryptedKeys } = request.body;

        const isInConversation = await db.query(
            'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
            [conversationId, userId]
        );

        if (isInConversation.rowCount === 0) {
            return reply.code(403).send({ error: 'You are not in this conversation' });
        }

        try {
            await db.query(
            'INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys) VALUES ($1, $2, $3, $4)',
            [conversationId, userId, encryptedMessage, encryptedKeys]
            );

            return reply.code(201).send({ status: 'Message stored' });
        } catch (err) {
            request.log.error(err);
            return reply.code(500).send({ error: 'Message not stored' });
        }
        }
    });
}