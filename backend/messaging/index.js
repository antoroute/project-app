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

// HTTP Security & Performance
await fastify.register(fastifyCors, { origin: '*' });
await fastify.register(helmet);
await fastify.register(rateLimit, { max: 100, timeWindow: '1 minute' });

// JWT Auth
await fastify.register(fastifyJWT, { secret: process.env.JWT_SECRET });
fastify.decorate('authenticate', async (request, reply) => {
  try { await request.jwtVerify(); }
  catch (err) { reply.code(401).send({ error: 'Invalid or expired token' }); }
});

// Database connection
await connectDB(fastify); // adds fastify.pg

// Setup HTTP routes
groupRoutes(fastify);
conversationRoutes(fastify);
fastify.get('/health', async () => 'Messaging OK');

// Create HTTP server for WS
const server = createServer((req, res) => fastify.server.emit('request', req, res));

// Initialize and configure Socket.io before Fastify starts
const io = new Server(server, { cors: { origin: '*', methods: ['GET','POST'] } });

// Redis adapter for Socket.io
const pubClient = createClient({ url: process.env.REDIS_URL });
const subClient = pubClient.duplicate();
await pubClient.connect();
await subClient.connect();
io.adapter(createAdapter(pubClient, subClient));

// Presence service
const presenceService = await createPresenceService(process.env.REDIS_URL);
// Decorate before start
fastify.decorate('presence', presenceService);
fastify.decorate('io', io);

// Register WS authentication
socketAuthMiddleware(io, fastify);

// Wait for Fastify to be ready
await fastify.ready();

// Handle WS connections
io.on('connection', (socket) => {
  const userId = socket.user.id;
  fastify.log.info(`User connected: ${userId}`);

  socket.join(`user:${userId}`);
  socket.joinedConversations = new Set();

  socket.on('conversation:subscribe', async (conversationId, ack) => {
    socket.join(conversationId);
    socket.joinedConversations.add(conversationId);
    await fastify.presence.addUser(conversationId, userId);
    if (ack) ack({ success: true });
  });

  socket.on('conversation:unsubscribe', async (conversationId) => {
    socket.leave(conversationId);
    socket.joinedConversations.delete(conversationId);
    await fastify.presence.removeUser(conversationId, userId);
  });

  socket.on('disconnect', async () => {
    for (const convoId of socket.joinedConversations) {
      await fastify.presence.removeUser(convoId, userId);
    }
    fastify.log.info(`User disconnected: ${userId}`);
  });
});

// Start server
server.listen({ port: process.env.PORT || 3001, host: '0.0.0.0' }, () => {
  fastify.log.info(`🚀 Messaging service listening on port ${process.env.PORT || 3001}`);
});