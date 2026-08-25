// backend/messaging/src/index.ts
// Point d'entrée Fastify + Socket.IO pour le service Messaging (v2).
// – JWT obligatoire (même secret que ton service Auth)
// – CORS/Helmet/Rate Limit conseillés (ajoute selon ton projet)
// – Enregistre les routes et services (presence, ACL, messages v2, groups, conversations)

import Fastify from 'fastify';
import fastifyCors from '@fastify/cors';
import fastifyHelmet from '@fastify/helmet';
import { Server as IOServer } from 'socket.io';

import { loadConfig } from './config.js';
import { assertAccessClaims, registerAccessJwt } from './security/jwt.js';
import dbPlugin from './plugins/db.js';
import enforceVersion from './middlewares/enforceVersion.js';
import validateAppSecret from './middlewares/validateAppSecret.js';
import socketAuth from './middlewares/socketAuth.js';
import type { AppDatabase } from './plugins/db.js';

// Routes 
import keysDevicesRoutes from './routes/keys.devices.js';
import accountDeviceRoutes from './routes/account.devices.js';
import accountDeviceApprovalRoutes from './routes/account.deviceApprovals.js';
import messagesV2Routes from './routes/messages.v2.js';
import conversationsRoutes from './routes/conversations.js';
import groupsRoutes from './routes/groups.js';

// Services 
import { initPresenceService } from './services/presence.js';
import { initAclService } from './services/acl.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: AppDatabase;
    io: IOServer;
    services: {
      presence: ReturnType<typeof initPresenceService>;
      acl: ReturnType<typeof initAclService>;
    };
    authenticate: (req: any, reply: any) => Promise<void>;
  }
}

async function build() {
  const config = loadConfig();
  const app = Fastify({ logger: true });

  // Pré-déclarer les décorateurs AVANT démarrage
  app.decorate('io', undefined as unknown as IOServer);
  app.decorate('services', {} as any);

  // Plugins Fastify
  await app.register(fastifyHelmet, { contentSecurityPolicy: false });
  await app.register(fastifyCors, { origin: true, credentials: true });
  await registerAccessJwt(app, config.jwtAccessPublicKey);

  app.decorate('authenticate', async (req: any, reply: any) => {
    try {
      const payload = await req.jwtVerify();
      req.user = assertAccessClaims(payload);
    } catch {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });

  // DB + health
  await app.register(dbPlugin, { connectionString: config.databaseUrl });

  // Health AVANT enforceVersion (et whiteliste dans le middleware)
  app.get('/health', async () => ({ ok: true }));

  await app.register(enforceVersion);
  await app.register(validateAppSecret, { appSecret: config.appSecret });

  // Routes REST
  await app.register(keysDevicesRoutes);
  await app.register(accountDeviceRoutes);
  await app.register(accountDeviceApprovalRoutes);
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
    presence: initPresenceService(io, app),
    acl: initAclService(app),
  };

  // Auth WS + rooms
  io.use(socketAuth(app, config.appSecret));
  io.on('connection', (socket) => {
    const { userId } = (socket as any).auth;
    socket.join(`user:${userId}`);
    
    // Métriques de connexion
    app.log.info({ 
      userId, 
      socketId: socket.id, 
      timestamp: new Date().toISOString(),
      event: 'user_connected'
    }, 'User WebSocket connected');
    
    // CORRECTION: Rejoindre automatiquement les rooms de groupes de l'utilisateur
    app.services.acl.listAccessibleGroupIds(userId)
      .then((groupIds: string[]) => {
        groupIds.forEach((groupId: string) => {
          socket.join(`group:${groupId}`);
          app.log.info({ 
            userId, 
            groupId,
            socketId: socket.id,
            event: 'group_room_joined'
          }, 'User auto-joined group room');
        });
        app.log.info({ 
          userId, 
          groupCount: groupIds.length,
          socketId: socket.id,
          event: 'all_group_rooms_joined'
        }, 'User auto-joined group rooms');
      })
      .catch((err: any) => {
        app.log.error({ 
          userId, 
          error: err,
          socketId: socket.id,
          event: 'group_room_join_failed'
        }, 'Failed to auto-join group rooms');
      });
    
    // ✅ OPTIMISATION: Fonction helper pour émettre les événements de présence de manière optimisée
    async function emitBatchPresenceEvents(
      socket: any, 
      convIds: string[], 
      userId: string, 
      app: any
    ) {
      // Pour chaque conversation, envoyer un seul événement avec toutes les présences
      for (const convId of convIds) {
        const conversationRoom = `conv:${convId}`;
        const socketsInConversation = app.io.sockets.adapter.rooms.get(conversationRoom);
        
        if (!socketsInConversation) continue;
        
        // Compter les sockets par utilisateur
        const presenceMap = new Map<string, number>();
        const otherUsersPresence: Array<{userId: string, online: boolean, count: number}> = [];
        
        for (const socketId of socketsInConversation) {
          const otherSocket = app.io.sockets.sockets.get(socketId);
          if (otherSocket && otherSocket.id !== socket.id) {
            const otherUserId = (otherSocket as any).auth?.userId;
            if (otherUserId) {
              presenceMap.set(otherUserId, (presenceMap.get(otherUserId) || 0) + 1);
            }
          }
        }
        
        // ✅ OPTIMISÉ: Envoyer un seul événement avec toutes les présences
        if (presenceMap.size > 0) {
          for (const [otherUserId, socketCount] of presenceMap.entries()) {
            otherUsersPresence.push({
              userId: otherUserId,
              online: true,
              count: socketCount
            });
          }
          
          // Envoyer toutes les présences en un seul événement
          socket.emit('presence:conversation:batch', {
            conversationId: convId,
            presences: otherUsersPresence
          });
          
          app.log.info({ 
            convId, 
            userId, 
            presenceCount: otherUsersPresence.length 
          }, 'Sent batch presence state to new subscriber');
        }
        
        // Notifier les autres utilisateurs de la présence du nouvel arrivant
        const userSocketsInConversation = Array.from(socketsInConversation || []).filter(socketId => {
          const s = app.io.sockets.sockets.get(socketId);
          return s && (s as any).auth?.userId === userId;
        });
        
        socket.to(conversationRoom).emit('presence:conversation', {
          userId,
          online: true,
          count: userSocketsInConversation.length,
          conversationId: convId
        });
      }
    }

    // Gestion des abonnements aux conversations
    socket.on('conv:subscribe', async (data: any) => {
      const convId = data.convId || data;
      const roomName = `conv:${convId}`;

      const hasAccess = await app.services.acl.hasConversationPermission(
        userId,
        convId,
        'socket:subscribe',
      );
      if (!hasAccess) {
        socket.emit('conv:subscribe', { success: false, error: 'forbidden' });
        app.log.warn({ convId, userId }, 'Unauthorized conversation subscription attempt');
        return;
      }

      // L'accès est revérifié même si le socket se trouve déjà dans la room.
      const room = app.io.sockets.adapter.rooms.get(roomName);
      if (room && room.has(socket.id)) {
        app.log.info({ convId, userId }, 'User already subscribed to conversation');
        socket.emit('conv:subscribe', { success: true, convId, alreadySubscribed: true });
        return;
      }

      socket.join(roomName);
      socket.emit('conv:subscribe', { success: true, convId });
      app.log.info({ convId, userId }, 'User subscribed to conversation');

      // ✅ OPTIMISÉ: Utiliser la fonction helper pour les événements de présence
      await emitBatchPresenceEvents(socket, [convId], userId, app);
    });
    
    // ✅ NOUVEAU: Endpoint batch pour abonner plusieurs conversations en une requête
    socket.on('conv:subscribe:batch', async (data: any) => {
      const convIds = Array.isArray(data.convIds) ? data.convIds : [data.convId];
      
      if (convIds.length === 0) {
        socket.emit('conv:subscribe:batch', { success: false, error: 'No conversation IDs provided' });
        return;
      }
      
      app.log.info({ userId, count: convIds.length }, 'Batch subscription request');
      
      const authorizedConvIds =
        await app.services.acl.listAccessibleConversationIds(userId, convIds);
      const unauthorizedCount = convIds.length - authorizedConvIds.length;
      
      // Abonner à toutes les conversations autorisées
      const subscribed: string[] = [];
      const alreadySubscribed: string[] = [];
      
      for (const convId of authorizedConvIds) {
        const roomName = `conv:${convId}`;
        const room = app.io.sockets.adapter.rooms.get(roomName);
        
        if (room && room.has(socket.id)) {
          alreadySubscribed.push(convId);
        } else {
          socket.join(roomName);
          subscribed.push(convId);
        }
      }
      
      // ✅ OPTIMISÉ: Émettre les événements de présence de manière batch
      if (subscribed.length > 0) {
        await emitBatchPresenceEvents(socket, subscribed, userId, app);
      }
      
      socket.emit('conv:subscribe:batch', {
        success: true,
        subscribed: subscribed.length,
        alreadySubscribed: alreadySubscribed.length,
        unauthorized: unauthorizedCount,
        convIds: subscribed
      });
      
      app.log.info({ 
        userId, 
        subscribed: subscribed.length,
        alreadySubscribed: alreadySubscribed.length,
        unauthorized: unauthorizedCount
      }, 'Batch subscription completed');
    });
    
    socket.on('conv:unsubscribe', async (data: any) => {
      const convId = data.convId || data;
      const conversationRoom = `conv:${convId}`;
      socket.leave(conversationRoom);

      if (!(await app.services.acl.hasConversationPermission(
        userId,
        convId,
        'socket:subscribe',
      ))) {
        app.log.warn({ convId, userId }, 'Conversation room left without presence emission after ACL refusal');
        return;
      }
      app.log.info({ convId, userId }, 'User unsubscribed from conversation');
      
      // CORRECTION: Émettre la présence de l'utilisateur comme hors ligne dans cette conversation
      // Vérifier si l'utilisateur a encore des sockets dans cette conversation
      const socketsInConversation = app.io.sockets.adapter.rooms.get(conversationRoom);
      const userSocketsInConversation = Array.from(socketsInConversation || []).filter(socketId => {
        const socket = app.io.sockets.sockets.get(socketId);
        return socket && (socket as any).auth?.userId === userId;
      });
      
      const isOnlineInConversation = userSocketsInConversation.length > 0;
      socket.to(`conv:${convId}`).emit('presence:conversation', { 
        userId, 
        online: isOnlineInConversation, 
        count: userSocketsInConversation.length,
        conversationId: convId 
      });
      app.log.info({ convId, userId, isOnlineInConversation }, 'Presence updated on conversation unsubscribe');
    });
    
    // Gestion des indicateurs de frappe avec vérification de sécurité
    socket.on('typing:start', async (data: any) => {
      const convId = data.convId;
      if (convId) {
        const isInConversation =
          await app.services.acl.hasConversationPermission(
            userId,
            convId,
            'typing:emit',
          );
        
        if (isInConversation) {
          // Broadcaster à tous les autres utilisateurs dans la conversation
          socket.to(`conv:${convId}`).emit('typing:start', { convId, userId });
          app.log.debug({ convId, userId }, 'User started typing');
        } else {
          app.log.warn({ convId, userId }, 'Unauthorized typing event');
        }
      }
    });
    
    socket.on('typing:stop', async (data: any) => {
      const convId = data.convId;
      if (convId) {
        const isInConversation =
          await app.services.acl.hasConversationPermission(
            userId,
            convId,
            'typing:emit',
          );
        
        if (isInConversation) {
          // Broadcaster à tous les autres utilisateurs dans la conversation
          socket.to(`conv:${convId}`).emit('typing:stop', { convId, userId });
          app.log.debug({ convId, userId }, 'User stopped typing');
        } else {
          app.log.warn({ convId, userId }, 'Unauthorized typing event');
        }
      }
    });

    app.services.presence.onConnect(socket);
    
    // Métriques de déconnexion
    socket.on('disconnect', (reason) => {
      app.log.info({ 
        userId, 
        socketId: socket.id, 
        reason,
        timestamp: new Date().toISOString(),
        event: 'user_disconnected'
      }, 'User WebSocket disconnected');
      
      app.services.presence.onDisconnect(socket);
    });
  });

  await app.listen({ port: config.port, host: '0.0.0.0' });
  app.log.info(`Messaging v2 listening on ${config.port}`);
}

build().catch((e) => {
  console.error(e);
  process.exit(1);
});
