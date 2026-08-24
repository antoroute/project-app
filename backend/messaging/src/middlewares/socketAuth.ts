import { FastifyInstance } from 'fastify';
import { Socket } from 'socket.io';

import { verifyAccessToken } from '../security/jwt.js';

export default function socketAuth(app: FastifyInstance, appSecret: string) {
  return async (socket: Socket, next: (err?: any) => void) => {
    try {
      // 🔐 Vérifier le App Secret pour les WebSockets
      const providedSecret = String(socket.handshake.headers['x-app-secret'] || '').trim();
      if (providedSecret !== appSecret) {
        app.log.warn({
          socketId: socket.id,
          ip: socket.handshake.address,
          providedSecret: providedSecret ? '***' : '(missing)',
        }, 'Unauthorized WebSocket connection attempt - invalid app secret');
        return next(new Error('invalid app secret'));
      }

      const header = socket.handshake.headers?.authorization as string | undefined;
      const bearer = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
      const token = (socket.handshake.auth?.token as string) || bearer;
      if (!token) return next(new Error('no token'));

      const payload = verifyAccessToken(app, token);
      (socket as any).auth = { userId: payload.sub };
      next();
    } catch (err: any) {
      if (err.message === 'invalid app secret') {
        next(err);
      } else {
        next(new Error('invalid token'));
      }
    }
  };
}
