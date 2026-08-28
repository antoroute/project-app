import 'fastify';
import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Server as IOServer } from 'socket.io';

import type { AuthenticatedAccountDevice } from '../middlewares/deviceAuth.js';

declare module 'fastify' {
  interface FastifyRequest {
    accountDevice: AuthenticatedAccountDevice | null;
  }

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
    identifyDevice: (
      request: FastifyRequest,
      reply: FastifyReply,
    ) => Promise<void>;
    requireActiveDevice: (
      request: FastifyRequest,
      reply: FastifyReply,
    ) => Promise<void>;
  }
}

export {};
