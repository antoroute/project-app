// Déclarations Fastify côté Messaging (db, io, services, authenticate, jwt)
import type { Server as IOServer } from 'socket.io';

declare module 'fastify' {
  interface FastifyInstance {
    db: {
      query: (text: string, params?: any[]) => Promise<any>;
      one: (text: string, params?: any[]) => Promise<any>;
      any: (text: string, params?: any[]) => Promise<any[]>;
      none: (text: string, params?: any[]) => Promise<void>;
    };
    io: IOServer;
    services: {
      presence: {
        onConnect: (socket: any) => void;
        onDisconnect: (socket: any) => void;
        isOnline: (userId: string) => boolean;
      };
      acl: {
        canSend: (
          senderUserId: string,
          senderDeviceId: string,
          groupId: string,
          convId: string,
          recipients: Array<{ userId: string; deviceId: string }>
        ) => Promise<boolean>;
        markConversationRead: (convId: string, userId: string) => Promise<string>;
        listReaders: (
          convId: string
        ) => Promise<Array<{ userId: string; username: string; lastReadAt: string | null }>>;
      };
    };
    authenticate: (req: any, reply: any) => Promise<void>;
    jwt: any;
  }
}
