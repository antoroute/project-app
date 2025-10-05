// backend/messaging/src/services/presence.ts
// Suivi présence par userId/deviceId via Socket.IO – publication d'événements.

import { Server, Socket } from 'socket.io';

type PresenceState = Map<string /*userId*/, Set<string /*socket.id*/>>;

export function initPresenceService(io: Server) {
  const state: PresenceState = new Map();

  function onConnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    console.log(`[Presence] User ${userId} connected with socket ${socket.id}`);
    if (!state.has(userId)) state.set(userId, new Set());
    state.get(userId)!.add(socket.id);

    // Émettre à TOUS les sockets connectés (broadcast global)
    const count = state.get(userId)!.size;
    console.log(`[Presence] Broadcasting presence:update for ${userId} - online: true, count: ${count}`);
    io.emit('presence:update', { userId, online: true, count });
  }

  function onDisconnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    console.log(`[Presence] User ${userId} disconnected with socket ${socket.id}`);
    const set = state.get(userId);
    if (!set) return;
    set.delete(socket.id);
    const online = set.size > 0;
    
    // Émettre à TOUS les sockets connectés (broadcast global)
    const count = set.size;
    console.log(`[Presence] Broadcasting presence:update for ${userId} - online: ${online}, count: ${count}`);
    io.emit('presence:update', { userId, online, count });
  }

  function isOnline(userId: string) {
    return state.get(userId)?.size ? true : false;
    }

  return { onConnect, onDisconnect, isOnline };
}
