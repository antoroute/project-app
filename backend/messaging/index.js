import Fastify from 'fastify';
import fastifyJWT from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import helmet from '@fastify/helmet';
import { Server } from 'socket.io';
import { createServer } from 'http';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';
import { groupRoutes } from './routes/groups.js';
import { conversationRoutes } from './routes/conversations.js';
import { connectDB } from './plugins/db.js';

const fastify = Fastify({ logger: true });

await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(fastifyJWT, {
  secret: process.env.JWT_SECRET
});

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

// Redis adapter pour Socket.IO
try {
  const pubClient = createClient({ url: 'redis://redis:6379' });
  const subClient = pubClient.duplicate();
  await pubClient.connect();
  await subClient.connect();
  io.adapter(createAdapter(pubClient, subClient));
  console.log('Redis adapter for Socket.IO is ready');
} catch (err) {
  console.error('Redis adapter connection failed:', err);
}

socketAuthMiddleware(io, fastify);

io.on('connection', (socket) => {
  console.log('Authenticated user connected:', socket.user.id);

  socket.on('conversation:subscribe', (conversationId) => {
    socket.join(conversationId);
    console.log(`Socket ${socket.id} joined conversation ${conversationId}`);
  });

  socket.on('message:send', async (payload) => {
    const { conversationId, encryptedMessage, encryptedKeys } = payload;
    const senderId = socket.user.id;

    try {
      const isInConversation = await fastify.pg.query(
        'SELECT 1 FROM conversation_users WHERE conversation_id = $1 AND user_id = $2',
        [conversationId, senderId]
      );

      if (isInConversation.rowCount === 0) {
        return socket.emit('error', 'You are not a member of this conversation');
      }

      await fastify.pg.query(
        'INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys) VALUES ($1, $2, $3, $4)',
        [conversationId, senderId, encryptedMessage, encryptedKeys]
      );
      console.log('Message sent:', { conversationId, senderId, encryptedMessage, encryptedKeys });
      // Emit the message to all users in the conversation
      io.in(conversationId).emit('message:new', { 
        senderId, 
        conversationId, 
        encryptedMessage, 
        encryptedKeys 
      });
    } catch (err) {
      console.error('[Socket message:send]', err);
      socket.emit('error', 'Internal error while sending message');
    }
  });

  socket.on('disconnect', () => {
    console.log('User disconnected:', socket.user.id);
  });
});

server.listen({ port: process.env.PORT || 3001, host: '0.0.0.0' }, () => {
  console.log(`Messaging service listening on port ${process.env.PORT || 3001}`);
});
