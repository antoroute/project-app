// backend/messaging/src/middlewares/socketAuth.ts
// Authentifie les sockets via le même JWT que les routes REST.

import { FastifyInstance } from 'fastify';
import { Socket } from 'socket.io';

export default function socketAuth(app: FastifyInstance) {
  return async (socket: Socket, next: (err?: any) => void) => {
    try {
      const header = socket.handshake.headers?.authorization;
      const token = (socket.handshake.auth?.token as string)
        || (header?.startsWith('Bearer ') ? header.slice(7) : undefined);
      if (!token) return next(new Error('no token'));

      const payload = await (app as any).jwt.verify(token);
      (socket as any).auth = { userId: payload.sub, token };
      next();
    } catch {
      next(new Error('invalid token'));
    }
  };
}
