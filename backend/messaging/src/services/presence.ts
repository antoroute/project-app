// backend/messaging/src/services/presence.ts
// Suivi présence par userId/deviceId via Socket.IO – publication d'événements.

import { Server, Socket } from 'socket.io';

type PresenceState = Map<string /*userId*/, Set<string /*socket.id*/>>;

export function initPresenceService(io: Server) {
  const state: PresenceState = new Map();

  function onConnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    if (!state.has(userId)) state.set(userId, new Set());
    state.get(userId)!.add(socket.id);

    // Émettre à TOUS les sockets connectés (broadcast global)
    io.emit('presence:update', { userId, online: true, count: state.get(userId)!.size });
  }

  function onDisconnect(socket: Socket) {
    const { userId } = (socket as any).auth;
    const set = state.get(userId);
    if (!set) return;
    set.delete(socket.id);
    const online = set.size > 0;
    
    // Émettre à TOUS les sockets connectés (broadcast global)
    io.emit('presence:update', { userId, online, count: set.size });
  }

  function isOnline(userId: string) {
    return state.get(userId)?.size ? true : false;
    }

  return { onConnect, onDisconnect, isOnline };
}
