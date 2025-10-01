// backend/auth/src/types/fastify.d.ts
// Déclarations d'augmentation pour Fastify côté "auth".

declare module 'fastify' {
  interface FastifyInstance {
    db: {
      query: (text: string, params?: any[]) => Promise<any>;
      one: (text: string, params?: any[]) => Promise<any>;
      any: (text: string, params?: any[]) => Promise<any[]>;
      none: (text: string, params?: any[]) => Promise<void>;
    };

    // Hook d'auth REST
    authenticate: (req: any, reply: any) => Promise<void>;

    // Plugin JWT (sign/verify)
    jwt: {
      sign: (payload: any, opts?: any) => Promise<string>;
      verify: (token: string, opts?: any) => Promise<any>;
    };
  }
}
