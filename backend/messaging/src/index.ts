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
    presence: initPresenceService(io, app),
    acl: initAclService(app),
  };

  // Auth WS + rooms
  io.use(socketAuth(app));
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
    app.db.any(`SELECT group_id FROM user_groups WHERE user_id = $1`, [userId])
      .then((groups: any[]) => {
        groups.forEach((group: any) => {
          socket.join(`group:${group.group_id}`);
          app.log.info({ 
            userId, 
            groupId: group.group_id,
            socketId: socket.id,
            event: 'group_room_joined'
          }, 'User auto-joined group room');
        });
        app.log.info({ 
          userId, 
          groupCount: groups.length,
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
    
    // Gestion des abonnements aux conversations
    socket.on('conv:subscribe', async (data: any) => {
      const convId = data.convId || data;
      
      // Vérifier que l'utilisateur a accès à cette conversation
      const hasAccess = await app.db.oneOrNone(
        `SELECT 1 FROM conversation_users cu 
         JOIN conversations c ON cu.conversation_id = c.id 
         WHERE cu.user_id = $1 AND c.id = $2`,
        [userId, convId]
      );
      
      if (hasAccess) {
        socket.join(`conv:${convId}`);
        socket.emit('conv:subscribe', { success: true, convId });
        app.log.info({ convId, userId }, 'User subscribed to conversation');
        
        // CORRECTION: Émettre la présence de l'utilisateur dans cette conversation
        // Vérifier combien de sockets de cet utilisateur sont dans cette conversation
        const conversationRoom = `conv:${convId}`;
        const socketsInConversation = app.io.sockets.adapter.rooms.get(conversationRoom);
        const userSocketsInConversation = Array.from(socketsInConversation || []).filter(socketId => {
          const socket = app.io.sockets.sockets.get(socketId);
          return socket && (socket as any).auth?.userId === userId;
        });
        
        socket.to(`conv:${convId}`).emit('presence:conversation', {
          userId,
          online: true,
          count: userSocketsInConversation.length,
          conversationId: convId
        });
        app.log.info({ convId, userId, socketCount: userSocketsInConversation.length }, 'Presence broadcasted to conversation');
        
        // NOUVEAU: Envoyer l'état de présence actuel de tous les autres utilisateurs au nouvel arrivant
        const conversationRoomSockets = app.io.sockets.adapter.rooms.get(conversationRoom);
        if (conversationRoomSockets) {
          const presenceMap = new Map<string, number>();
          
          // Compter les sockets par utilisateur dans cette conversation
          for (const socketId of conversationRoomSockets) {
            const otherSocket = app.io.sockets.sockets.get(socketId);
            if (otherSocket && otherSocket.id !== socket.id) {
              const otherUserId = (otherSocket as any).auth?.userId;
              if (otherUserId) {
                presenceMap.set(otherUserId, (presenceMap.get(otherUserId) || 0) + 1);
              }
            }
          }
          
          // Envoyer l'état de présence de chaque utilisateur au nouvel arrivant
          for (const [otherUserId, socketCount] of presenceMap.entries()) {
            socket.emit('presence:conversation', {
              userId: otherUserId,
              online: true,
              count: socketCount,
              conversationId: convId
            });
            app.log.info({ convId, userId, otherUserId, socketCount }, 'Sent current presence state to new subscriber');
          }
        }
      } else {
        socket.emit('conv:subscribe', { success: false, error: 'Unauthorized' });
        app.log.warn({ convId, userId }, 'Unauthorized conversation subscription attempt');
      }
    });
    
    socket.on('conv:unsubscribe', (data: any) => {
      const convId = data.convId || data;
      socket.leave(`conv:${convId}`);
      app.log.info({ convId, userId }, 'User unsubscribed from conversation');
      
      // CORRECTION: Émettre la présence de l'utilisateur comme hors ligne dans cette conversation
      // Vérifier si l'utilisateur a encore des sockets dans cette conversation
      const conversationRoom = `conv:${convId}`;
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
        // Vérifier que l'utilisateur est dans la conversation
        const isInConversation = await app.db.oneOrNone(
          `SELECT 1 FROM conversation_users WHERE user_id = $1 AND conversation_id = $2`,
          [userId, convId]
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
        // Vérifier que l'utilisateur est dans la conversation
        const isInConversation = await app.db.oneOrNone(
          `SELECT 1 FROM conversation_users WHERE user_id = $1 AND conversation_id = $2`,
          [userId, convId]
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

  const port = Number(process.env.PORT || 3001);
  await app.listen({ port, host: '0.0.0.0' });
  app.log.info(`Messaging v2 listening on ${port}`);
}

build().catch((e) => {
  console.error(e);
  process.exit(1);
});
