import { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { Type } from '@sinclair/typebox';
import bcrypt from 'bcrypt';

import { signAccessToken, signRefreshToken, verifyRefreshToken } from '../security/jwt.js';

const RegisterBody = Type.Object({
  email: Type.String({ format: 'email' }),
  username: Type.String({ minLength: 3, maxLength: 64 }),
  password: Type.String({ minLength: 8 })
});

const LoginBody = Type.Object({
  email: Type.String({ format: 'email' }),
  password: Type.String({ minLength: 8 })
});

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
    const userId = (req.user as any).sub;
    const user = await app.db.one(`SELECT id, email, username, created_at FROM users WHERE id=$1`, [userId]);
    return user;
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
