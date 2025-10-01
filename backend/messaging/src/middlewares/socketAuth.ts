import { FastifyInstance } from 'fastify';
import { Socket } from 'socket.io';

export default function socketAuth(app: FastifyInstance) {
  return async (socket: Socket, next: (err?: any) => void) => {
    try {
      const header = socket.handshake.headers?.authorization as string | undefined;
      const bearer = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
      const token = (socket.handshake.auth?.token as string) || bearer;
      if (!token) return next(new Error('no token'));

      const payload = await (app as any).jwt.verify(token);
      (socket as any).auth = { userId: payload.sub, token };
      next();
    } catch {
      next(new Error('invalid token'));
    }
  };
}
