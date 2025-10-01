// backend/messaging/src/types/fastify.d.ts
// Déclarations d'augmentation pour Fastify côté "messaging".
// Cela évite les erreurs TS "Property 'xxx' does not exist on type 'FastifyInstance'".

import type { Server as IOServer } from 'socket.io';

declare module 'fastify' {
  interface FastifyInstance {
    // Exposé par plugins/db.ts
    db: {
      query: (text: string, params?: any[]) => Promise<any>;
      one: (text: string, params?: any[]) => Promise<any>;
      any: (text: string, params?: any[]) => Promise<any[]>;
      none: (text: string, params?: any[]) => Promise<void>;
    };

    // Exposé dans index.ts
    io: IOServer;

    // Ajouté dans index.ts (services/presence + services/acl)
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
        listReaders: (convId: string) => Promise<Array<{ userId: string; username: string; lastReadAt: string | null }>>;
      };
    };

    // Hook d'auth REST (req.jwtVerify déjà fourni par @fastify/jwt)
    authenticate: (req: any, reply: any) => Promise<void>;
    // Accès direct au plugin JWT si besoin
    jwt: any;
  }
}
