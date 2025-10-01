// backend/auth/src/types/fastify.d.ts
import type {
  FastifyInstance as FI,
  RawServerDefault,
  RawRequestDefaultExpression,
  RawReplyDefaultExpression,
  FastifyBaseLogger,
  FastifyTypeProviderDefault
} from 'fastify';

declare module 'fastify' {
  interface FastifyInstance<
    RawServer = RawServerDefault,
    RawRequest = RawRequestDefaultExpression,
    RawReply = RawReplyDefaultExpression,
    Logger = FastifyBaseLogger,
    TypeProvider = FastifyTypeProviderDefault
  > {
    db: {
      query: (text: string, params?: any[]) => Promise<any>;
      one: (text: string, params?: any[]) => Promise<any>;
      any: (text: string, params?: any[]) => Promise<any[]>;
      none: (text: string, params?: any[]) => Promise<void>;
    };
    authenticate: (req: any, reply: any) => Promise<void>;
    jwt: {
      sign: (payload: any, opts?: any) => Promise<string>;
      verify: (token: string, opts?: any) => Promise<any>;
    };
  }
}
