// backend/messaging/src/services/presence.ts
// Suivi présence par userId/deviceId via Socket.IO – publication d'événements.

import { Server, Socket } from 'socket.io';

type PresenceState = Map<string /*userId*/, Set<string /*socket.id*/>>;

export function initPresenceService(io: Server, app: any) {
  const state: PresenceState = new Map();
  
  function getUserSocketCount(userId: string): number {
    return state.get(userId)?.size || 0;
  }

  function broadcastPresenceToGroups(userId: string, online: boolean, count: number) {
    app.services.acl.listAccessibleGroupIds(userId)
      .then((groupIds: string[]) => {
        groupIds.forEach((groupId: string) => {
          io.to(`group:${groupId}`).emit('presence:update', { userId, online, count });
        });
      })
      .catch((err: any) => {
        app.log.error({ err, userId }, 'Unable to resolve presence groups');
      });
  }

  function broadcastPresenceToConversations(userId: string, online: boolean, count: number) {
    app.services.acl.listAllAccessibleConversationIds(userId)
      .then((conversationIds: string[]) => {
        conversationIds.forEach((conversationId: string) => {
          io.to(`conv:${conversationId}`).emit('presence:conversation', {
            userId, 
            online, 
            count,
            conversationId,
          });
        });
      })
      .catch((err: any) => {
        app.log.error({ err, userId }, 'Unable to resolve presence conversations');
      });
  }

  function onConnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    console.log(`[Presence] User ${userId} connected with socket ${socket.id}`);
    if (!state.has(userId)) state.set(userId, new Set());
    state.get(userId)!.add(socket.id);

    // CORRECTION: Émettre uniquement aux utilisateurs dans les mêmes groupes
    const count = state.get(userId)!.size;
    console.log(`[Presence] Broadcasting presence:update for ${userId} - online: true, count: ${count}`);
    
    // Utiliser les fonctions helper pour broadcaster la présence
    broadcastPresenceToGroups(userId, true, count);
    broadcastPresenceToConversations(userId, true, count);
    
    // CORRECTION: Envoyer l'état de présence actuel uniquement aux groupes communs
    // Pour chaque utilisateur en ligne, vérifier s'il est dans les mêmes groupes que le nouvel utilisateur
    console.log(`[Presence] Broadcasting current presence state to user's groups (filtered by membership)`);
    app.services.acl.listAccessibleGroupIds(userId)
      .then((userGroupIdsList: string[]) => {
        console.log(`[Presence] User ${userId} is in ${userGroupIdsList.length} groups`);
        const userGroupIds = new Set(userGroupIdsList);
        
        // Pour chaque utilisateur en ligne, vérifier s'il est dans les mêmes groupes
        for (const [uid, socketSet] of state.entries()) {
          if (socketSet.size > 0 && uid !== userId) {
            // Vérifier si cet utilisateur est dans au moins un groupe commun
            app.services.acl.listAccessibleGroupIds(uid)
              .then((otherUserGroupIdsList: string[]) => {
                const otherUserGroupIds = new Set(otherUserGroupIdsList);
                const commonGroups = Array.from(userGroupIds).filter(gid => otherUserGroupIds.has(gid));
                
                // Émettre la présence uniquement dans les groupes communs
                commonGroups.forEach((groupId: string) => {
                  io.to(`group:${groupId}`).emit('presence:update', { 
                    userId: uid, 
                    online: true, 
                    count: socketSet.size 
                  });
                });
                
                if (commonGroups.length > 0) {
                  console.log(`[Presence] Broadcasted presence of ${uid} to ${commonGroups.length} common groups`);
                }
              })
              .catch((err: any) => {
                console.error(`[Presence] Error checking groups for user ${uid}:`, err);
              });
          }
        }
      })
      .catch((err: any) => {
        console.error(`[Presence] Error broadcasting presence state for ${userId}:`, err);
      });
  }

  function onDisconnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    console.log(`[Presence] User ${userId} disconnected with socket ${socket.id}`);
    const set = state.get(userId);
    if (!set) return;
    set.delete(socket.id);
    const online = set.size > 0;
    
    // CORRECTION: Émettre uniquement aux utilisateurs dans les mêmes groupes
    const count = set.size;
    console.log(`[Presence] Broadcasting presence:update for ${userId} - online: ${online}, count: ${count}`);
    
    // Utiliser les fonctions helper pour broadcaster la présence
    broadcastPresenceToGroups(userId, online, count);
    broadcastPresenceToConversations(userId, online, count);
  }

  function isOnline(userId: string) {
    return state.get(userId)?.size ? true : false;
  }

  function broadcastUserPresence(userId: string, online: boolean, count: number) {
    broadcastPresenceToGroups(userId, online, count);
    broadcastPresenceToConversations(userId, online, count);
  }

  return { onConnect, onDisconnect, isOnline, broadcastUserPresence, getUserSocketCount };
}
