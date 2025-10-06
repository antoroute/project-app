import 'fastify';
import type { Server as IOServer } from 'socket.io';

declare module 'fastify' {
  interface FastifyInstance {
    db: {
      query: (q: string, p?: any[]) => Promise<any>;
      one: (q: string, p?: any[]) => Promise<any>;
      oneOrNone: (q: string, p?: any[]) => Promise<any | null>;
      any: (q: string, p?: any[]) => Promise<any[]>;
      none: (q: string, p?: any[]) => Promise<void>;
    };
    io: IOServer;
    services: {
      presence: any;
      acl: any;
    };
    authenticate: (req: any, reply: any) => Promise<void>;
  }
}

export {};
