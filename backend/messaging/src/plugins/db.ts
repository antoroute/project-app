// backend/messaging/src/plugins/db.ts
// Plugin DB simple basé sur node-postgres (pg).
// Adapte si tu utilises pg-promise ou autre ORM.

import { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';
import { Pool } from 'pg';

const dbPlugin: FastifyPluginAsync = async (app) => {
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL || 'postgres://postgres:postgres@postgres:5432/postgres',
  });

  app.decorate('db', {
    query: (q: string, p?: any[]) => pool.query(q, p),
    one: async (q: string, p?: any[]) => {
      const r = await pool.query(q, p);
      if (!r.rows.length) throw new Error('No rows');
      return r.rows[0];
    },
    any: async (q: string, p?: any[]) => (await pool.query(q, p)).rows,
    none: async (q: string, p?: any[]) => { await pool.query(q, p); }
  });

  app.addHook('onClose', async () => { await pool.end(); });
};

export default fp(dbPlugin);
