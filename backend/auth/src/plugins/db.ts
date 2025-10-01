// backend/auth/src/plugins/db.ts
import fp from 'fastify-plugin';
import { Pool } from 'pg';
import type { FastifyInstance } from 'fastify';

export default fp(async function (app: FastifyInstance) {
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@postgres:5432/postgres',
  });

  app.decorate('db', {
    query: (text: string, params?: any[]) => pool.query(text, params),
    one: async (text: string, params?: any[]) => {
      const r = await pool.query(text, params);
      if (!r.rows.length) throw new Error('No rows');
      return r.rows[0];
    },
    any: async (text: string, params?: any[]) => (await pool.query(text, params)).rows,
    none: async (text: string, params?: any[]) => { await pool.query(text, params); },
  });

  app.addHook('onClose', async () => { await pool.end(); });
});
