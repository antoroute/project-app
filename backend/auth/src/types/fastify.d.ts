import 'fastify';

declare module 'fastify' {
  interface FastifyInstance {
    db: {
      query: (q: string, p?: any[]) => Promise<any>;
      one: (q: string, p?: any[]) => Promise<any>;
      any: (q: string, p?: any[]) => Promise<any[]>;
      none: (q: string, p?: any[]) => Promise<void>;
    };
    authenticate: (req: any, reply: any) => Promise<void>;
  }
}

export {};
