import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';
import { randomBytes, scrypt as _scrypt, timingSafeEqual } from 'crypto';
import { promisify } from 'util';

const scrypt = promisify(_scrypt);

const SCRYPT_N = 16384;
const SCRYPT_r = 8;
const SCRYPT_p = 1;
const KEYLEN = 64;
const SALT_LEN = 16;

async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(SALT_LEN);
  const key = (await scrypt(password, salt, KEYLEN, { N: SCRYPT_N, r: SCRYPT_r, p: SCRYPT_p })) as Buffer;
  return ['scrypt', SCRYPT_N, SCRYPT_r, SCRYPT_p, salt.toString('base64'), key.toString('base64')].join('$');
}

async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const N = parseInt(parts[1], 10);
  const r = parseInt(parts[2], 10);
  const p = parseInt(parts[3], 10);
  const salt = Buffer.from(parts[4], 'base64');
  const key = Buffer.from(parts[5], 'base64');
  const derived = (await scrypt(password, salt, key.length, { N, r, p })) as Buffer;
  return timingSafeEqual(derived, key);
}

const RegisterBody = Type.Object({
  email: Type.String({ format: 'email' }),
  username: Type.String({ minLength: 3, maxLength: 64 }),
  password: Type.String({ minLength: 8 })
});

const LoginBody = Type.Object({
  email: Type.String({ format: 'email' }),
  password: Type.String({ minLength: 8 })
});

export default async function routes(app: FastifyInstance) {
  app.post('/register', { schema: { body: RegisterBody } }, async (req: any, reply: any) => {
    const { email, username, password } = req.body as any;
    const hash = await hashPassword(password);
    try {
      const user = await app.db.one(
        `INSERT INTO users(email, username, password)
         VALUES($1,$2,$3)
         RETURNING id, email, username, created_at`,
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

  app.post('/login', { schema: { body: LoginBody } }, async (req: any, reply: any) => {
    const { email, password } = req.body as any;
    const row = await app.db.one(
      `SELECT id, email, username, password FROM users WHERE email=$1`,
      [email]
    ).catch(() => null);
    if (!row) return reply.code(401).send({ error: 'invalid_credentials' });

    const ok = await verifyPassword(password, row.password);
    if (!ok) return reply.code(401).send({ error: 'invalid_credentials' });

    const access = await app.jwt.sign({ username: row.username }, { subject: row.id, expiresIn: '15m' });
    const refresh = await app.jwt.sign({ type: 'refresh' }, { subject: row.id, expiresIn: '30d' });

    await app.db.none(
      `INSERT INTO refresh_tokens(user_id, token_hash, expires_at)
       VALUES($1, crypt($2, gen_salt('bf')), NOW() + interval '30 days')`,
      [row.id, refresh]
    );

    return reply.send({ access, refresh, user: { id: row.id, email: row.email, username: row.username } });
  });

  app.post('/refresh', async (req: any, reply: any) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(401).send({ error: 'no_token' });
    const token = auth.slice(7);

    let payload: any;
    try { payload = await app.jwt.verify(token); }
    catch { return reply.code(401).send({ error: 'invalid_token' }); }
    if (payload.type !== 'refresh') return reply.code(400).send({ error: 'not_refresh' });

    const ok = await app.db.any(
      `SELECT 1 FROM refresh_tokens
        WHERE user_id=$1
          AND crypt($2, token_hash) = token_hash
          AND expires_at > NOW()`,
      [payload.sub, token]
    );
    if (!ok.length) return reply.code(401).send({ error: 'revoked' });

    const access = await app.jwt.sign({}, { subject: payload.sub, expiresIn: '15m' });
    return reply.send({ access });
  });

  app.get('/me', { onRequest: [app.authenticate] }, async (req: any, reply: any) => {
    const userId = (req.user as any).sub;
    const user = await app.db.one(
      `SELECT id, email, username, created_at FROM users WHERE id=$1`,
      [userId]
    );
    return user;
  });

  app.post('/logout', async (req: any, reply: any) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(400).send({ ok: true });
    const token = auth.slice(7);
    await app.db.none(
      `DELETE FROM refresh_tokens
        WHERE crypt($1, token_hash) = token_hash`,
      [token]
    );
    return { ok: true };
  });
}
