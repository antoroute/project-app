// Déclarations Fastify côté Auth (db, authenticate, jwt)
declare module 'fastify' {
  interface FastifyInstance {
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
