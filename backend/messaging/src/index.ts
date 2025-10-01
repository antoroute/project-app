// backend/messaging/src/index.ts
// Entrée Fastify + Socket.IO pour le service Messaging (v2).
// - JWT vérifié (même secret que Auth), avec verify.allowedIss/allowedAud cohérents
// - CORS / Helmet / Rate-limit
// - Routes: keys.devices, messages v2, conversations, groups
// - WS: auth middleware, rooms user/conv, présence

import Fastify, { FastifyReply, FastifyRequest } from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import http from 'node:http';
import { Server as IOServer } from 'socket.io';

import dbPlugin from './plugins/db.js';
import socketAuth from './middlewares/socketAuth.js';

import keysDevicesRoutes from './routes/keys.devices.js';
import messagesV2Routes from './routes/messages.v2.js';
import conversationsRoutes from './routes/conversations.js';
import groupsRoutes from './routes/groups.js';

import { initPresenceService } from './services/presence.js';
import { initAclService } from './services/acl.js';

async function build() {
  const app = Fastify({ logger: true });

  // Sécurité & CORS
  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  await app.register(rateLimit, { max: 400, timeWindow: '1 minute' });

  // DB
  await app.register(dbPlugin);

  // JWT (vérification uniquement côté messaging)
  // Aligne avec Auth: tokens émis par Auth doivent avoir `iss` et (optionnel) `aud`.
  const ISSUER = process.env.JWT_ISSUER || 'auth-service';
  const AUDIENCE = process.env.JWT_AUDIENCE || 'messaging';
  await app.register(fastifyJwt, {
    secret: process.env.JWT_SECRET || 'dev-secret',
    verify: {
      // si Auth signe avec iss="auth-service" et aud="messaging"
      allowedIss: ISSUER,
      allowedAud: AUDIENCE
    }
    // NOTE: pas besoin de 'sign' côté messaging, on ne génère pas de JWT ici.
  });

  // Décorateur d’auth pour les routes REST protégées
  app.decorate('authenticate', async (req: FastifyRequest, reply: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      return reply.code(401).send({ error: 'unauthorized' });
    }
  });

  // HTTP server + Socket.IO
  const server = http.createServer(app as any);
  const io = new IOServer(server, {
    path: '/socket',
    cors: { origin: true, credentials: true }
  });
  (app as any).io = io;

  // Services
  (app as any).services = {
    presence: initPresenceService(io),
    acl: initAclService(app)
  };

  // WS: auth + rooms
  io.use(socketAuth(app));
  io.on('connection', (socket) => {
    const { userId } = (socket as any).auth;
    // Room par user
    socket.join(`user:${userId}`);

    // Abonnements conv
    socket.on('conv:subscribe', (convId: string) => socket.join(`conv:${convId}`));
    socket.on('conv:unsubscribe', (convId: string) => socket.leave(`conv:${convId}`));

    // Presence
    (app as any).services.presence.onConnect(socket);
    socket.on('disconnect', () => (app as any).services.presence.onDisconnect(socket));
  });

  // Routes REST
  app.register(keysDevicesRoutes);
  app.register(messagesV2Routes);
  app.register(conversationsRoutes);
  app.register(groupsRoutes);

  // Health
  app.get('/health', async (_req: FastifyRequest, reply: FastifyReply) => {
    return reply.send({ ok: true });
  });

  // Démarrage
  const port = Number(process.env.PORT || 3001);
  const host = '0.0.0.0';
  server.listen(port, host, () => app.log.info(`Messaging v2 listening on ${host}:${port}`));

  return { app, server, io };
}

build().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
