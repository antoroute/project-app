// backend/messaging/src/index.ts
// Point d'entrée Fastify + Socket.IO pour le service Messaging (v2).
// – JWT obligatoire (même secret que ton service Auth)
// – CORS/Helmet/Rate Limit conseillés (ajoute selon ton projet)
// – Enregistre les routes et services (presence, ACL, messages v2, groups, conversations)

import Fastify from 'fastify';
import fastifyJwt from '@fastify/jwt';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import { Server as IOServer } from 'socket.io';
import http from 'node:http';

import dbPlugin from './plugins/db';
import socketAuth from './middlewares/socketAuth';

import keysDevicesRoutes from './routes/keys.devices';
import messagesV2Routes from './routes/messages.v2';
import conversationsRoutes from './routes/conversations';
import groupsRoutes from './routes/groups';

import { initPresenceService } from './services/presence';
import { initAclService } from './services/acl';

declare module 'fastify' {
  interface FastifyInstance {
    db: any;       // pg-promise / node-postgres wrapper (exposé par plugins/db)
    io: IOServer;  // Socket.IO
    services: {
      presence: ReturnType<typeof initPresenceService>,
      acl: ReturnType<typeof initAclService>,
    };
    authenticate: any; // hook JWT
  }
}

async function build() {
  const app = Fastify({ logger: true });

  // Sécurité & CORS (ajuste les origines)
  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });

  // JWT : DOIT correspondre à Auth
  await app.register(fastifyJwt, {
    secret: process.env.JWT_SECRET || 'dev-secret',
    sign: { issuer: 'project-app', audience: 'messaging' }
  });
  app.decorate('authenticate', async (req: any, reply) => {
    try { await req.jwtVerify(); } catch (e) { reply.code(401).send({ error: 'unauthorized' }); }
  });

  // DB
  await app.register(dbPlugin);

  // HTTP server + Socket.IO
  const server = http.createServer(app as any);
  const io = new IOServer(server, {
    path: '/socket',
    cors: { origin: true, credentials: true }
  });
  app.decorate('io', io);

  // Services
  app.decorate('services', {
    presence: initPresenceService(io),
    acl: initAclService(app),
  });

  // WS auth + rooms
  io.use(socketAuth(app));
  io.on('connection', (socket) => {
    const { userId } = (socket as any).auth;
    // Rooms utiles : par user et par conv (abonnements dynamiques côté client)
    socket.join(`user:${userId}`);

    socket.on('conv:subscribe', (convId: string) => socket.join(`conv:${convId}`));
    socket.on('conv:unsubscribe', (convId: string) => socket.leave(`conv:${convId}`));

    // Presence service (connect/disconnect)
    app.services.presence.onConnect(socket);
    socket.on('disconnect', () => app.services.presence.onDisconnect(socket));
  });

  // Routes REST
  app.register(keysDevicesRoutes);
  app.register(messagesV2Routes);
  app.register(conversationsRoutes);
  app.register(groupsRoutes);

  app.get('/health', async () => ({ ok: true }));

  // Démarrage
  const port = Number(process.env.PORT || 3001);
  server.listen(port, '0.0.0.0', () => app.log.info(`Messaging v2 listening on ${port}`));
  return { app, server, io };
}

build().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
