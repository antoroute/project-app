import Fastify from 'fastify';
import fastifyJWT from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import { Server } from 'socket.io';
import { createServer } from 'http';
import { createAdapter } from '@socket.io/redis-adapter';
import { createClient } from 'redis';
import dotenv from 'dotenv';
import { socketAuthMiddleware } from './middlewares/socketAuth.js';
import { groupRoutes } from './routes/groups.js';
import { conversationRoutes } from './routes/conversations.js';
import { connectDB } from './plugins/db.js';
import { createPresenceService } from './services/presence.js';

dotenv.config();
const fastify = Fastify({ logger: true });

// Sécurité HTTP et performances
await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(rateLimit, { max: 100, timeWindow: '1 minute' });

// JWT
await fastify.register(fastifyJWT, { secret: process.env.JWT_SECRET });
fastify.decorate('authenticate', async (request, reply) => {
  try { await request.jwtVerify(); }
  catch (err) { reply.code(401).send({ error: 'Invalid or expired token' }); }
});

// Connexion à la BDD
await connectDB(fastify); // décore fastify.pg

// Routes HTTP
groupRoutes(fastify);
conversationRoutes(fastify);
fastify.get('/health', async () => 'Messaging OK');

await fastify.ready();

// HTTP Server + WebSocket
const server = createServer((req, res) => fastify.server.emit('request', req, res));
const io = new Server(server, { cors: { origin: '*', methods: ['GET','POST'] } });

// Redis adapter pour Socket.io
const pubClient = createClient({ url: process.env.REDIS_URL });
const subClient = pubClient.duplicate();
await pubClient.connect();
await subClient.connect();
io.adapter(createAdapter(pubClient, subClient));

// Service de présence
const presenceService = await createPresenceService(process.env.REDIS_URL);
fastify.decorate('presence', presenceService);
fastify.decorate('io', io);

// Authentification WebSocket
socketAuthMiddleware(io, fastify);

io.on('connection', (socket) => {
  const userId = socket.user.id;
  fastify.log.info(`User connected: ${userId}`);

  // Room privé user
  socket.join(`user:${userId}`);
  socket.joinedConversations = new Set();

  // Souscription à une conversation
  socket.on('conversation:subscribe', async (conversationId, ack) => {
    socket.join(conversationId);
    socket.joinedConversations.add(conversationId);
    await fastify.presence.addUser(conversationId, userId);
    if (ack) ack({ success: true });
  });

  // Désinscription
  socket.on('conversation:unsubscribe', async (conversationId) => {
    socket.leave(conversationId);
    socket.joinedConversations.delete(conversationId);
    await fastify.presence.removeUser(conversationId, userId);
  });

  // Déconnexion
  socket.on('disconnect', async () => {
    for (const convoId of socket.joinedConversations) {
      await fastify.presence.removeUser(convoId, userId);
    }
    fastify.log.info(`User disconnected: ${userId}`);
  });
});

server.listen({ port: process.env.PORT || 3001, host: '0.0.0.0' }, () => {
  fastify.log.info(`🚀 Messaging service listening on port ${process.env.PORT || 3001}`);
});