import type { FastifyPluginAsync } from 'fastify';
import fp from 'fastify-plugin';
import pg from 'pg';
const { Pool } = pg;

type Queryable = Pick<pg.PoolClient, 'query'>;

export interface DbExecutor {
  query: (query: string, params?: any[]) => Promise<pg.QueryResult>;
  one: (query: string, params?: any[]) => Promise<any>;
  oneOrNone: (query: string, params?: any[]) => Promise<any | null>;
  any: (query: string, params?: any[]) => Promise<any[]>;
  none: (query: string, params?: any[]) => Promise<void>;
}

export interface TransactionOptions {
  isolationLevel?: 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE';
  maxRetries?: number;
}

export interface AppDatabase extends DbExecutor {
  transaction: <T>(
    work: (transaction: DbExecutor) => Promise<T>,
    options?: TransactionOptions,
  ) => Promise<T>;
}

export function createDbExecutor(queryable: Queryable): DbExecutor {
  return {
    query: (query: string, params?: any[]) => queryable.query(query, params),
    one: async (query: string, params?: any[]) => {
      const result = await queryable.query(query, params);
      if (!result.rows.length) throw new Error('No rows');
      return result.rows[0];
    },
    oneOrNone: async (query: string, params?: any[]) => {
      const result = await queryable.query(query, params);
      return result.rows.length ? result.rows[0] : null;
    },
    any: async (query: string, params?: any[]) =>
      (await queryable.query(query, params)).rows,
    none: async (query: string, params?: any[]) => {
      await queryable.query(query, params);
    },
  };
}

function isRetryableTransactionError(error: unknown): boolean {
  const code = (error as { code?: string } | null)?.code;
  return code === '40001' || code === '40P01';
}

export async function runInTransaction<T>(
  pool: Pick<pg.Pool, 'connect'>,
  work: (transaction: DbExecutor) => Promise<T>,
  options: TransactionOptions = {},
): Promise<T> {
  const isolationLevel = options.isolationLevel ?? 'READ COMMITTED';
  const maxRetries = options.maxRetries ?? 2;

  for (let attempt = 0; ; attempt += 1) {
    const client = await pool.connect();
    let releaseError: Error | undefined;
    try {
      await client.query(`BEGIN ISOLATION LEVEL ${isolationLevel}`);
      const result = await work(createDbExecutor(client));
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch (rollbackError) {
        releaseError = rollbackError instanceof Error
          ? rollbackError
          : new Error('Transaction rollback failed');
      }
      if (!isRetryableTransactionError(error) || attempt >= maxRetries) {
        throw error;
      }
    } finally {
      client.release(releaseError);
    }
  }
}

interface DbPluginOptions {
  connectionString: string;
}

const dbPlugin: FastifyPluginAsync<DbPluginOptions> = async (app, options) => {
  const pool = new Pool({
    connectionString: options.connectionString,
  });

  const executor = createDbExecutor(pool);
  const database: AppDatabase = {
    ...executor,
    transaction: (work, transactionOptions) =>
      runInTransaction(pool, work, transactionOptions),
  };
  app.decorate('db', database);

  app.addHook('onClose', async () => {
    await pool.end();
  });
};

export default fp(dbPlugin);
