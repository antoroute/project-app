import fp from 'fastify-plugin';
import pkg from 'pg';
const { Pool } = pkg;

async function dbConnector(fastify) {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  fastify.decorate('pg', pool);
}

export const connectDB = fp(dbConnector);