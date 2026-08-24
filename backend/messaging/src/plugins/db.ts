import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';
import pg from 'pg';
const { Pool } = pg;

interface DbPluginOptions {
  connectionString: string;
}

const dbPlugin: FastifyPluginAsync<DbPluginOptions> = async (app, options) => {
  const pool = new Pool({
    connectionString: options.connectionString,
  });

  app.decorate('db', {
    query: (q: string, p?: any[]) => pool.query(q, p),
    one: async (q: string, p?: any[]) => {
      const r = await pool.query(q, p);
      if (!r.rows.length) throw new Error('No rows');
      return r.rows[0];
    },
    oneOrNone: async (q: string, p?: any[]) => {
      const r = await pool.query(q, p);
      return r.rows.length ? r.rows[0] : null;
    },
    any: async (q: string, p?: any[]) => (await pool.query(q, p)).rows,
    none: async (q: string, p?: any[]) => {
      await pool.query(q, p);
    },
  });

  app.addHook('onClose', async () => {
    await pool.end();
  });
};

export default fp(dbPlugin);
