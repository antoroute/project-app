// backend/messaging/src/services/presence.ts
// Suivi présence par userId/deviceId via Socket.IO – publication d'événements.

import { Server, Socket } from 'socket.io';

type PresenceState = Map<string /*userId*/, Set<string /*socket.id*/>>;

export function initPresenceService(io: Server, app: any) {
  const state: PresenceState = new Map();

  function onConnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    console.log(`[Presence] User ${userId} connected with socket ${socket.id}`);
    if (!state.has(userId)) state.set(userId, new Set());
    state.get(userId)!.add(socket.id);

    // CORRECTION: Émettre uniquement aux utilisateurs dans les mêmes groupes
    const count = state.get(userId)!.size;
    console.log(`[Presence] Broadcasting presence:update for ${userId} - online: true, count: ${count}`);
    
    // Récupérer les groupes de l'utilisateur et broadcaster uniquement aux membres de ces groupes
    app.db.any(`SELECT group_id FROM user_groups WHERE user_id = $1`, [userId])
      .then((userGroups: any[]) => {
        userGroups.forEach((group: any) => {
          io.to(`group:${group.group_id}`).emit('presence:update', { userId, online: true, count });
        });
      })
      .catch((err: any) => {
        console.error(`[Presence] Error getting user groups for ${userId}:`, err);
      });
    
    // CORRECTION: Envoyer l'état de présence actuel uniquement aux groupes de l'utilisateur
    console.log(`[Presence] Broadcasting current presence state to user's groups`);
    app.db.any(`SELECT group_id FROM user_groups WHERE user_id = $1`, [userId])
      .then((userGroups: any[]) => {
        userGroups.forEach((group: any) => {
          for (const [uid, socketSet] of state.entries()) {
            if (socketSet.size > 0) {
              io.to(`group:${group.group_id}`).emit('presence:update', { userId: uid, online: true, count: socketSet.size });
            }
          }
        });
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
    
    // Récupérer les groupes de l'utilisateur et broadcaster uniquement aux membres de ces groupes
    app.db.any(`SELECT group_id FROM user_groups WHERE user_id = $1`, [userId])
      .then((userGroups: any[]) => {
        userGroups.forEach((group: any) => {
          io.to(`group:${group.group_id}`).emit('presence:update', { userId, online, count });
        });
      })
      .catch((err: any) => {
        console.error(`[Presence] Error getting user groups for ${userId}:`, err);
      });
  }

  function isOnline(userId: string) {
    return state.get(userId)?.size ? true : false;
    }

  return { onConnect, onDisconnect, isOnline };
}
