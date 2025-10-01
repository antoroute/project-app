// backend/messaging/src/middlewares/socketAuth.ts
// Authentifie les sockets via le même JWT que les routes REST.

import { FastifyInstance } from 'fastify';
import { Socket } from 'socket.io';

export default function socketAuth(app: FastifyInstance) {
  return async (socket: Socket, next: (err?: any) => void) => {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.headers?.authorization?.replace('Bearer ', '');
      if (!token) return next(new Error('Authentication token missing'));
      const payload = await (app as any).jwt.verify(token);
      (socket as any).auth = { userId: payload.sub, token };
      next();
    } catch (e) {
      next(new Error('Invalid or expired token'));
    }
  };
}
