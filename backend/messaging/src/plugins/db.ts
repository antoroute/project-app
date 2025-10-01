// backend/messaging/src/plugins/db.ts
// Plugin DB simple basé sur node-postgres (pg).
// Adapte si tu utilises pg-promise ou autre ORM.

import { FastifyInstance } from 'fastify';
import fp from 'fastify-plugin';
import { Pool } from 'pg';

export default fp(async function (app: FastifyInstance) {
  const pool = new Pool({
    connectionString: process.env.DATABASE_URL ||
      `postgres://postgres:postgres@postgres:5432/postgres`,
  });

  // expose un petit helper
  app.decorate('db', {
    query: (text: string, params?: any[]) => pool.query(text, params),
    one: async (text: string, params?: any[]) => {
      const r = await pool.query(text, params);
      if (r.rows.length === 0) throw new Error('No rows');
      return r.rows[0];
    },
    any: async (text: string, params?: any[]) => {
      const r = await pool.query(text, params);
      return r.rows;
    },
    none: async (text: string, params?: any[]) => {
      await pool.query(text, params);
    },
  });

  app.addHook('onClose', async () => {
    await pool.end();
  });
});
