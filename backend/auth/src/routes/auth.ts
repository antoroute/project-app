import { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { Type } from '@sinclair/typebox';
import bcrypt from 'bcrypt';
import { createHash, randomBytes } from 'node:crypto';

import {
  authenticatedUserId,
  signAccessToken,
  signRefreshToken,
  verifyRefreshToken,
} from '../security/jwt.js';

const Email = Type.String({
  format: 'email',
  minLength: 3,
  maxLength: 254,
});
const Password = Type.String({ minLength: 8, maxLength: 1024 });
const Username = Type.String({
  minLength: 3,
  maxLength: 64,
  pattern: '^(?!\\s)(?!.*\\s$)[^\\u0000-\\u001F\\u007F]+$',
});

const RegisterBody = Type.Object(
  { email: Email, username: Username, password: Password },
  { additionalProperties: false },
);

const LoginBody = Type.Object(
  { email: Email, password: Password },
  { additionalProperties: false },
);

const DeviceBootstrapGrantBody = Type.Object(
  { password: Type.String({ minLength: 8, maxLength: 1024 }) },
  { additionalProperties: false },
);

const DEVICE_BOOTSTRAP_GRANT_TTL_SECONDS = 5 * 60;

function bearerToken(header: string | undefined): string | null {
  const match = header?.match(/^Bearer ([^\s]+)$/);
  return match?.[1] ?? null;
}

export default async function routes(app: FastifyInstance) {

  app.post('/register', {
    schema: { body: RegisterBody }
  }, async (req: FastifyRequest, reply: FastifyReply) => {
    const { email, username, password } = req.body as any;
    const hash = await bcrypt.hash(password, 12);
    try {
      const user = await app.db.one(
        `INSERT INTO users(email, username, password)
         VALUES($1,$2,$3) RETURNING id, email, username, created_at`,
        [email, username, hash]
      );
      reply.code(201).send(user);
    } catch (e: any) {
      if (String(e.message).includes('duplicate key')) {
        return reply.code(409).send({ error: 'email_exists' });
      }
      throw e;
    }
  });

  app.post('/login', {
    schema: { body: LoginBody }
  }, async (req: FastifyRequest, reply: FastifyReply) => {
    const { email, password } = req.body as any;

    const row = await app.db.one(
      `SELECT id, email, username, password FROM users WHERE email=$1`,
      [email]
    ).catch(() => null);
    if (!row) return reply.code(401).send({ error: 'invalid_credentials' });

    const ok = await bcrypt.compare(password, row.password);
    if (!ok) return reply.code(401).send({ error: 'invalid_credentials' });

    const access = signAccessToken(app, row.id);
    const refresh = signRefreshToken(app, row.id);
    const refreshClaims = verifyRefreshToken(app, refresh);

    await app.db.none(
      `INSERT INTO refresh_tokens(user_id, token_hash, expires_at)
       VALUES($1, encode(digest($2, 'sha256'), 'hex'), to_timestamp($3))`,
      [row.id, refresh, refreshClaims.exp]
    );

    return reply.send({ access, refresh, user: { id: row.id, email: row.email, username: row.username } });
  });

  app.post('/refresh', {}, async (req: FastifyRequest, reply: FastifyReply) => {
    const token = bearerToken(req.headers.authorization);
    if (!token) return reply.code(401).send({ error: 'no_token' });

    let payload;
    try { payload = verifyRefreshToken(app, token); }
    catch { return reply.code(401).send({ error: 'invalid_token' }); }

    const ok = await app.db.any(
      `SELECT 1 FROM refresh_tokens
        WHERE user_id=$1 AND token_hash = encode(digest($2, 'sha256'), 'hex')
          AND expires_at > NOW()`,
      [payload.sub, token]
    );
    if (!ok.length) return reply.code(401).send({ error: 'revoked' });

    const access = signAccessToken(app, payload.sub);
    return reply.send({ access });
  });

  app.get('/me', { onRequest: [app.authenticate] }, async (req: FastifyRequest, reply: FastifyReply) => {
    const userId = authenticatedUserId(req);
    const user = await app.db.one(`SELECT id, email, username, created_at FROM users WHERE id=$1`, [userId]);
    return user;
  });

  app.post('/device-bootstrap-grant', {
    onRequest: [app.authenticate],
    config: { rateLimit: { max: 5, timeWindow: '10 minutes' } },
    schema: {
      body: DeviceBootstrapGrantBody,
      response: {
        201: Type.Object({
          grant: Type.String({ minLength: 43, maxLength: 43 }),
          expiresAt: Type.String({ format: 'date-time' }),
        }),
      },
    },
  }, async (req: FastifyRequest, reply: FastifyReply) => {
    const userId = authenticatedUserId(req);
    const { password } = req.body as { password: string };
    const user = await app.db.one(
      'SELECT password FROM users WHERE id = $1',
      [userId],
    ).catch(() => null);
    if (!user || !(await bcrypt.compare(password, user.password))) {
      return reply.code(401).send({ error: 'invalid_credentials' });
    }

    const grant = randomBytes(32).toString('base64url');
    const grantHash = createHash('sha256').update(grant, 'ascii').digest();
    const expiresAtUnixSeconds =
      Math.floor(Date.now() / 1000) + DEVICE_BOOTSTRAP_GRANT_TTL_SECONDS;

    let createdGrant;
    try {
      createdGrant = await app.db.one(
        `WITH account_lock AS MATERIALIZED (
           SELECT pg_advisory_xact_lock(
             hashtextextended(($1::uuid)::text, 0)
           )
         ), cleanup AS (
         DELETE FROM device_bootstrap_grants
          WHERE user_id = $1::uuid
            AND COALESCE(consumed_at, expires_at) < NOW() - INTERVAL '7 days'
         ), recent AS (
           SELECT COUNT(*)::int AS count
             FROM device_bootstrap_grants, account_lock
            WHERE user_id = $1::uuid
              AND created_at > NOW() - INTERVAL '10 minutes'
         )
         INSERT INTO device_bootstrap_grants(user_id, token_hash, expires_at)
         SELECT $1::uuid,$2,to_timestamp($3)
           FROM recent
          WHERE recent.count < 5
         RETURNING id`,
        [userId, grantHash, expiresAtUnixSeconds],
      );
    } catch (error) {
      if ((error as Error).message !== 'No rows') throw error;
      createdGrant = null;
    }
    if (!createdGrant) {
      return reply.code(429).send({ error: 'too_many_bootstrap_grants' });
    }

    reply.code(201);
    return {
      grant,
      expiresAt: new Date(expiresAtUnixSeconds * 1000).toISOString(),
    };
  });

  app.post('/logout', {}, async (req: FastifyRequest, reply: FastifyReply) => {
    const token = bearerToken(req.headers.authorization);
    if (!token) return reply.code(200).send({ ok: true });

    let payload;
    try { payload = verifyRefreshToken(app, token); }
    catch { return reply.code(401).send({ error: 'invalid_token' }); }

    await app.db.none(
      `DELETE FROM refresh_tokens
       WHERE user_id=$1 AND token_hash = encode(digest($2, 'sha256'), 'hex')`,
      [payload.sub, token],
    );
    return { ok: true };
  });
}
