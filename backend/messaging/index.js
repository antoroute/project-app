import Fastify from 'fastify';
import fastifyJWT from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import helmet from '@fastify/helmet';
import { Server } from 'socket.io';
import { createServer } from 'http';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';
import dotenv from 'dotenv';
import { createVerify } from 'crypto';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';
import { groupRoutes } from './routes/groups.js';
import { conversationRoutes } from './routes/conversations.js';
import { connectDB } from './plugins/db.js';

dotenv.config();

const fastify = Fastify({ logger: true });

await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(fastifyJWT, { secret: process.env.JWT_SECRET });

fastify.decorate("authenticate", async function (request, reply) {
  try {
    await request.jwtVerify();
  } catch (err) {
    reply.code(401).send({ error: 'Invalid or expired token' });
  }
});

await connectDB(fastify);

groupRoutes(fastify);
conversationRoutes(fastify);

fastify.get('/health', async () => 'Messaging OK');

await fastify.ready();

const server = createServer((req, res) => fastify.server.emit('request', req, res));
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

try {
  const pubClient = createClient({ url: process.env.REDIS_URL });
  const subClient = pubClient.duplicate();
  await pubClient.connect();
  await subClient.connect();
  io.adapter(createAdapter(pubClient, subClient));
  console.log('✅ Redis adapter for Socket.IO is ready');
} catch (err) {
  console.error('❌ Redis adapter connection failed:', err);
}

socketAuthMiddleware(io, fastify);

io.on('connection', (socket) => {
  console.log('✅ Authenticated user connected:', socket.user.id);

  socket.on('conversation:subscribe', async (conversationId, ack) => {
    try {
      await socket.join(conversationId);
      console.log(`➡️ Socket ${socket.id} joined conversation ${conversationId}`);
      if (ack) ack({ success: true });
    } catch (err) {
      console.error('❌ Failed to join conversation:', err);
      if (ack) ack({ success: false, error: err.message });
    }
  });

  socket.on('conversation:unsubscribe', async (conversationId) => {
    try {
      await socket.leave(conversationId);
      console.log(`⬅️ Socket ${socket.id} left conversation ${conversationId}`);
    } catch (err) {
      console.error('❌ Failed to leave conversation:', err);
    }
  });

  socket.on('message:send', async (payload) => {
    try {
      const {
        conversationId,
        encrypted,
        iv,
        keys = {},
        signature,
        senderPublicKey
      } = payload || {};

      const senderId = socket.user.id;

      if (!conversationId || !encrypted || !iv || !signature || !senderPublicKey) {
        console.error('❌ Invalid payload:', payload);
        return socket.emit('error', { error: 'Invalid payload' });
      }

      const isInConversation = await fastify.pg.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, senderId]
      );

      if (isInConversation.rowCount === 0) {
        return socket.emit('error', { error: 'You are not a member of this conversation' });
      }

      // Vérification de la signature
      const verify = createVerify('SHA256');
      const canonicalPayload = JSON.stringify(Object.fromEntries(
        Object.entries({ encrypted, iv }).sort(([a], [b]) => a.localeCompare(b))
      ));
      verify.update(Buffer.from(canonicalPayload));
      verify.end();

      const isSignatureValid = verify.verify(senderPublicKey, Buffer.from(signature, 'base64'));

      if (!isSignatureValid) {
        console.error('❌ Invalid signature from user:', senderId);
        return socket.emit('error', { error: 'Invalid message signature' });
      }

      const encryptedMessageData = JSON.stringify({ encrypted, iv, signature, senderPublicKey });

      await fastify.pg.query(
        `INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys)
         VALUES ($1, $2, $3, $4)`,
        [conversationId, senderId, encryptedMessageData, keys]
      );

      console.log(`📨 Emitting message:new to conversation ${conversationId}`, { senderId });

      const newMessage = {
        senderId,
        conversationId,
        encrypted,
        iv,
        keys,
        signature,
        senderPublicKey
      };

      io.to(conversationId).emit('message:new', newMessage);
    } catch (err) {
      console.error('❌ [Socket message:send]', err);
      socket.emit('error', { error: 'Internal error while sending message' });
    }
  });

  socket.on('disconnect', () => {
    console.log('❌ User disconnected:', socket.user.id);
  });
});

server.listen({ port: process.env.PORT || 3001, host: '0.0.0.0' }, () => {
  console.log(`🚀 Messaging service listening on port ${process.env.PORT || 3001}`);
});
