import { createVerify } from 'crypto';

export function conversationRoutes(fastify) {
  const pool = fastify.pg;

  // Créer une conversation (privée ou subset)
  fastify.post('/conversations', {
    preHandler: fastify.authenticate,
    schema: {
      body: {
        type: 'object',
        required: ['groupId', 'userIds', 'encryptedSecrets', 'creatorSignature'],
        properties: {
          groupId: { type: 'string', format: 'uuid' },
          userIds: { type: 'array', items: { type: 'string', format: 'uuid' }, minItems: 1 },
          encryptedSecrets: { type: 'object' },
          creatorSignature: { type: 'string' }
        }
      }
    }
  }, async (request, reply) => {
    const { groupId, userIds, encryptedSecrets, creatorSignature } = request.body;
    const creatorId = request.user.id;

    // Vérifier que le créateur fait partie du groupe
    const inGroup = await pool.query(
      'SELECT 1 FROM user_groups WHERE user_id = $1 AND group_id = $2',
      [creatorId, groupId]
    );
    if (inGroup.rowCount === 0) {
      return reply.code(403).send({ error: 'You are not in this group' });
    }

    // Vérifier tous les userIds
    const membersRes = await pool.query(
      'SELECT user_id FROM user_groups WHERE group_id = $1 AND user_id = ANY($2)',
      [groupId, userIds]
    );
    if (membersRes.rowCount !== userIds.length) {
      return reply.code(400).send({ error: 'One or more users are not in the group' });
    }

    // Vérifier signature du créateur
    const keyRes = await pool.query(
      'SELECT public_key_group FROM user_groups WHERE user_id = $1 AND group_id = $2',
      [creatorId, groupId]
    );
    const publicKey = keyRes.rows[0]?.public_key_group;
    if (!publicKey) {
      return reply.code(400).send({ error: 'Missing public key for creator in group' });
    }
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

    // Créer la conversation
    const type = userIds.length === 1 ? 'private' : 'subset';
    const convoRes = await pool.query(
      `INSERT INTO conversations (group_id, type, creator_id, encrypted_secrets)
       VALUES ($1, $2, $3, $4) RETURNING id`,
      [groupId, type, creatorId, encryptedSecrets]
    );
    const conversationId = convoRes.rows[0].id;

    // Ajouter participants
    const allUserIds = [...new Set([...userIds, creatorId])];
    const values = allUserIds.map((_, i) => `($1, $${i+2})`).join(',');
    await pool.query(
      `INSERT INTO conversation_users (conversation_id, user_id) VALUES ${values}`,
      [conversationId, ...allUserIds]
    );

    // WS : notifie chaque user
    allUserIds.forEach(uid => {
      fastify.log.info(`Émission conversation:joined → user:${uid}`);
      fastify.io.to(`user:${uid}`).emit('conversation:joined', { conversationId });
    });

    return reply.code(201).send({ conversationId });
  });

  // Lister mes conversations
  fastify.get('/conversations', { preHandler: fastify.authenticate }, async (request, reply) => {
    const userId = request.user.id;
    const res = await pool.query(
      `SELECT c.id AS "conversationId", c.group_id AS "groupId", c.type, c.creator_id AS "creatorId", cu.last_read_at
         FROM conversation_users cu
         JOIN conversations c ON c.id = cu.conversation_id
        WHERE cu.user_id = $1
     ORDER BY c.created_at DESC`,
      [userId]
    );
    return reply.send(res.rows);
  });

  // Détails d’une conversation
  fastify.get('/conversations/:id', {
    preHandler: fastify.authenticate,
    schema: { params: { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } } }
  }, async (request, reply) => {
    const conversationId = request.params.id;
    const userId = request.user.id;
    const inConv = await pool.query(
      'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
      [conversationId, userId]
    );
    if (inConv.rowCount === 0) {
      return reply.code(403).send({ error: 'Access denied to this conversation' });
    }
    try {
      const convoRes = await pool.query(
        `SELECT id, group_id AS "groupId", type, creator_id AS "creatorId", encrypted_secrets AS "encryptedSecrets"
           FROM conversations WHERE id = $1`,
        [conversationId]
      );
      if (convoRes.rowCount === 0) return reply.code(404).send({ error: 'Conversation not found' });
      return reply.send(convoRes.rows[0]);
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to fetch conversation' });
    }
  });

  // Historique des messages
  fastify.get('/conversations/:id/messages', {
    preHandler: fastify.authenticate,
    schema: { params: { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } } }
  }, async (request, reply) => {
    const conversationId = request.params.id;
    const userId = request.user.id;
    const inConv = await pool.query(
      'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
      [conversationId, userId]
    );
    if (inConv.rowCount === 0) return reply.code(403).send({ error: 'Access denied to this conversation' });
    try {
      const msgsRes = await pool.query(
        `SELECT id, sender_id AS "senderId", encrypted_message, encrypted_keys, created_at, signature_valid
           FROM messages WHERE conversation_id = $1 ORDER BY created_at ASC`,
        [conversationId]
      );
      const messages = msgsRes.rows.map(msg => {
        let parsed = {};
        try { parsed = JSON.parse(msg.encrypted_message); } catch {}
        return {
          id: msg.id,
          senderId: msg.senderId,
          encrypted: parsed.encrypted || null,
          iv: parsed.iv || null,
          signature: parsed.signature || null,
          senderPublicKey: parsed.senderPublicKey || null,
          timestamp: Math.floor(new Date(msg.created_at).getTime()/1000),
          signatureValid: msg.signature_valid
        };
      });
      return reply.send(messages);
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Failed to fetch messages' });
    }
  });

  // Envoyer un message (fallback REST)
  fastify.post('/messages', {
    preHandler: fastify.authenticate,
    schema: { body: { type: 'object', required: ['conversationId','encrypted_message','encrypted_keys'], properties: { conversationId:{type:'string',format:'uuid'}, encrypted_message:{type:'string',minLength:10}, encrypted_keys:{type:'object'} } } }
  }, async (request, reply) => {
    const userId = request.user.id;
    const { conversationId, encrypted_message, encrypted_keys } = request.body;
    const inConv = await pool.query(
      'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
      [conversationId, userId]
    );
    if (inConv.rowCount === 0) return reply.code(403).send({ error: 'You are not in this conversation' });

    try {
      const envelope = JSON.parse(encrypted_message);
      const { encrypted, iv, signature, senderPublicKey } = envelope;
      const canonical = JSON.stringify({ encrypted, iv });
      const verify = createVerify('SHA256'); verify.update(Buffer.from(canonical)); verify.end();
      const isValid = verify.verify(senderPublicKey, Buffer.from(signature,'base64'));

      const insertRes = await pool.query(
        `INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys, signature_valid)
         VALUES ($1,$2,$3,$4,$5) RETURNING id, created_at`,
        [conversationId, userId, encrypted_message, encrypted_keys, isValid]
      );
      const msgRow = insertRes.rows[0];
      const newMessage = { id: msgRow.id, senderId: userId, conversationId, encrypted, iv, signatureValid: isValid, senderPublicKey, timestamp: Math.floor(new Date(msgRow.created_at).getTime()/1000) };

      // Broadcast WS
      fastify.io.to(conversationId).emit('message:new', newMessage);

      // Notifications
      const partsRes = await pool.query(
        'SELECT user_id FROM conversation_users WHERE conversation_id=$1 AND user_id!=$2',
        [conversationId,userId]
      );
      const active = await fastify.presence.getActiveUsers(conversationId);
      for (const {user_id:uid} of partsRes.rows) {
        if (!active.includes(uid)) {
          await pool.query(
            `INSERT INTO notifications (user_id,type,payload) VALUES ($1,$2,$3)`,
            [uid,'new_message',JSON.stringify({conversationId,message:newMessage})]
          );
          fastify.io.to(`user:${uid}`).emit('notification:new',{type:'new_message',payload:{conversationId,message:newMessage},createdAt:new Date().toISOString()});
        }
      }

      return reply.code(201).send({ status:'Message stored', message:newMessage });
    } catch (err) {
      request.log.error(err);
      return reply.code(500).send({ error: 'Message not stored' });
    }
  });

  // Ajouter un utilisateur à une conversation
  fastify.post('/conversations/:convId/users', {
    preHandler: fastify.authenticate,
    schema: { params:{type:'object',required:['convId'],properties:{convId:{type:'string',format:'uuid'}}}, body:{type:'object',required:['userId'],properties:{userId:{type:'string',format:'uuid'}}} }
  }, async (request, reply) => {
    const { convId } = request.params;
    const { userId: newUserId } = request.body;
    const isMember = await pool.query(
      'SELECT 1 FROM conversation_users WHERE conversation_id=$1 AND user_id=$2',
      [convId,request.user.id]
    );
    if (isMember.rowCount===0) return reply.code(403).send({ error:'Access denied' });

    await pool.query('INSERT INTO conversation_users(conversation_id,user_id) VALUES($1,$2)', [convId,newUserId]);
    fastify.io.to(convId).emit('conversation:user_added',{conversationId:convId,userId:newUserId});
    fastify.io.to(`user:${newUserId}`).emit('conversation:joined',{conversationId:convId});
    return reply.code(201).send({ status:'user added to conversation' });
  });
}