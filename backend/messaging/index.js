// /app/backend/messaging/index.js

import Fastify from 'fastify';
import fastifyJWT from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import helmet from '@fastify/helmet';
import { Server } from 'socket.io';
import { createServer } from 'http';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';
import { groupRoutes } from './routes/groups.js';
// import { conversationRoutes } from './routes/conversations.js';
import { connectDB } from './plugins/db.js';

const fastify = Fastify({ logger: true });

await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(fastifyJWT, {
  secret: process.env.JWT_SECRET
});

// Middleware JWT pour les routes REST
fastify.decorate("authenticate", async function (request, reply) {
  try {
    await request.jwtVerify();
  } catch (err) {
    reply.code(401).send({ error: 'Invalid or expired token' });
  }
});

// Connexion à PostgreSQL
await connectDB(fastify);

// Routes REST
groupRoutes(fastify);
// conversationRoutes(fastify);

// Important : s'assurer que Fastify est prêt avant de créer le serveur
await fastify.ready();

// Serveur HTTP manuellement créé pour intégrer Socket.IO
const server = createServer((req, res) => fastify.server.emit('request', req, res));
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST']
  }
});

// Authentification WebSocket via JWT
socketAuthMiddleware(io, fastify);

// Logique temps réel
io.on('connection', (socket) => {
  console.log('✅ Authenticated user connected:', socket.user.id);

  socket.on('message:send', async (payload) => {
    const { conversationId, encryptedMessage, encryptedKeys } = payload;
    const senderId = socket.user.id;

    try {
      await fastify.pg.query(
        'INSERT INTO messages (conversation_id, sender_id, encrypted_message, encrypted_keys) VALUES ($1, $2, $3, $4)',
        [conversationId, senderId, encryptedMessage, encryptedKeys]
      );

      io.to(conversationId).emit('message:new', {
        senderId,
        encryptedMessage,
        encryptedKeys
      });
    } catch (err) {
      console.error('[message:send]', err);
      socket.emit('error', 'Message could not be stored');
    }
  });
});

// Route santé
fastify.get('/health', async () => 'Messaging OK');

// Lancement du serveur HTTP + WebSocket
server.listen({ port: process.env.PORT || 3001, host: '0.0.0.0' }, () => {
  console.log(`Messaging service listening on port ${process.env.PORT || 3001}`);
});
