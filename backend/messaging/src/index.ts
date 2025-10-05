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

import dbPlugin from './plugins/db.js';
import enforceVersion from './middlewares/enforceVersion.js';
import socketAuth from './middlewares/socketAuth.js';

// Routes 
import keysDevicesRoutes from './routes/keys.devices.js';
import messagesV2Routes from './routes/messages.v2.js';
import conversationsRoutes from './routes/conversations.js';
import groupsRoutes from './routes/groups.js';

// Services 
import { initPresenceService } from './services/presence.js';
import { initAclService } from './services/acl.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: any;
    io: IOServer;
    services: {
      presence: ReturnType<typeof initPresenceService>;
      acl: ReturnType<typeof initAclService>;
    };
    authenticate: (req: any, reply: any) => Promise<void>;
  }
}

async function build() {
  const app = Fastify({ logger: true });

  // Pré-déclarer les décorateurs AVANT démarrage
  app.decorate('io', undefined as unknown as IOServer);
  app.decorate('services', {} as any);

  // Plugins Fastify
  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  await app.register(fastifyJwt, { secret: process.env.JWT_SECRET || 'dev-secret' });

  app.decorate('authenticate', async (req: any, reply: any) => {
    try { await req.jwtVerify(); } catch { reply.code(401).send({ error: 'unauthorized' }); }
  });

  // DB + health
  await app.register(dbPlugin);

  // Health AVANT enforceVersion (et whiteliste dans le middleware)
  app.get('/health', async () => ({ ok: true }));

  await app.register(enforceVersion);

  // Routes REST
  await app.register(keysDevicesRoutes);
  await app.register(messagesV2Routes);
  await app.register(conversationsRoutes);
  await app.register(groupsRoutes);

  // S’assurer que tous les plugins/routes sont prêts
  await app.ready();

  // Attacher Socket.IO au serveur natif Fastify
  const io = new IOServer(app.server, {
    path: '/socket',
    cors: { origin: true, credentials: true }
  });

  // NE PAS re-déclarer ici : on assigne sur les décorateurs déjà posés
  (app as any).io = io;

  // Services (présence, ACL)
  (app as any).services = {
    presence: initPresenceService(io),
    acl: initAclService(app),
  };

  // Auth WS + rooms
  io.use(socketAuth(app));
  io.on('connection', (socket) => {
    const { userId } = (socket as any).auth;
    socket.join(`user:${userId}`);
    
    // Gestion des abonnements aux conversations
    socket.on('conv:subscribe', (data: any) => {
      const convId = data.convId || data;
      socket.join(`conv:${convId}`);
      socket.emit('conv:subscribe', { success: true, convId });
      app.log.info({ convId, userId }, 'User subscribed to conversation');
    });
    
    socket.on('conv:unsubscribe', (data: any) => {
      const convId = data.convId || data;
      socket.leave(`conv:${convId}`);
      app.log.info({ convId, userId }, 'User unsubscribed from conversation');
    });
    
    // Gestion des indicateurs de frappe
    socket.on('typing:start', (data: any) => {
      const convId = data.convId;
      if (convId) {
        // Broadcaster à tous les autres utilisateurs dans la conversation
        socket.to(`conv:${convId}`).emit('typing:start', { convId, userId });
        app.log.debug({ convId, userId }, 'User started typing');
      }
    });
    
    socket.on('typing:stop', (data: any) => {
      const convId = data.convId;
      if (convId) {
        // Broadcaster à tous les autres utilisateurs dans la conversation
        socket.to(`conv:${convId}`).emit('typing:stop', { convId, userId });
        app.log.debug({ convId, userId }, 'User stopped typing');
      }
    });

    app.services.presence.onConnect(socket);
    socket.on('disconnect', () => app.services.presence.onDisconnect(socket));
  });

  const port = Number(process.env.PORT || 3001);
  await app.listen({ port, host: '0.0.0.0' });
  app.log.info(`Messaging v2 listening on ${port}`);
}

build().catch((e) => {
  console.error(e);
  process.exit(1);
});
