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

import dbPlugin from './plugins/db.js';
import socketAuth from './middlewares/socketAuth.js';

import keysDevicesRoutes from './routes/keys.devices.js';
import messagesV2Routes from './routes/messages.v2.js';
import conversationsRoutes from './routes/conversations.js';
import groupsRoutes from './routes/groups.js';

import { initPresenceService } from './services/presence.js';
import { initAclService } from './services/acl.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: any;
    io: IOServer;
    services: {
      presence: ReturnType<typeof initPresenceService>,
      acl: ReturnType<typeof initAclService>,
    };
    authenticate: any;
  }
}

async function build() {
  const app = Fastify({ logger: true });

  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });

  await app.register(fastifyJwt, { secret: process.env.JWT_SECRET || 'dev-secret' });
  app.decorate('authenticate', async (req: any, reply: any) => {
    try { await req.jwtVerify(); } catch { reply.code(401).send({ error: 'unauthorized' }); }
  });

  await app.register(dbPlugin);

  const server = http.createServer(app as any);
  const io = new IOServer(server, { path: '/socket', cors: { origin: true, credentials: true } });
  app.decorate('io', io);

  app.decorate('services', {
    presence: initPresenceService(io),
    acl: initAclService(app),
  });

  io.use(socketAuth(app));
  io.on('connection', (socket) => {
    const { userId } = (socket as any).auth;
    socket.join(`user:${userId}`);
    socket.on('conv:subscribe', (convId: string) => socket.join(`conv:${convId}`));
    socket.on('conv:unsubscribe', (convId: string) => socket.leave(`conv:${convId}`));

    app.services.presence.onConnect(socket);
    socket.on('disconnect', () => app.services.presence.onDisconnect(socket));
  });

  app.get('/health', async () => ({ ok: true }));

  app.register(keysDevicesRoutes);
  app.register(messagesV2Routes);
  app.register(conversationsRoutes);
  app.register(groupsRoutes);

  const port = Number(process.env.PORT || 3001);
  server.listen(port, '0.0.0.0', () => app.log.info(`Messaging v2 listening on ${port}`));
}
build().catch((e) => { console.error(e); process.exit(1); });
