import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';
import bcrypt from 'bcrypt';

declare module 'fastify' {
  interface FastifyInstance {
    db: any;
    authenticate: any;
  }
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

  // POST /auth/register
  app.post('/register', { schema: { body: RegisterBody } }, async (req, reply) => {
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

  // POST /auth/login
  app.post('/login', { schema: { body: LoginBody } }, async (req, reply) => {
    const { email, password } = req.body as any;

    const row = await app.db.one(`SELECT id, email, username, password FROM users WHERE email=$1`, [email])
      .catch(() => null);
    if (!row) return reply.code(401).send({ error: 'invalid_credentials' });

    const ok = await bcrypt.compare(password, row.password);
    if (!ok) return reply.code(401).send({ error: 'invalid_credentials' });

    // Access courts + refresh rotation (table refresh_tokens déjà en place)
    const access = await app.jwt.sign(
      { username: row.username },
      { subject: row.id, expiresIn: '15m' }
    );
    const refresh = await app.jwt.sign(
      { type: 'refresh' },
      { subject: row.id, expiresIn: '30d' }
    );

    // Stocker le hash du refresh (rotation rudimentaire)
    await app.db.none(
      `INSERT INTO refresh_tokens(user_id, token_hash, expires_at)
       VALUES($1, crypt($2, gen_salt('bf')), NOW() + interval '30 days')`,
      [row.id, refresh]
    );

    return reply.send({ access, refresh, user: { id: row.id, email: row.email, username: row.username } });
  });

  // POST /auth/refresh
  app.post('/refresh', async (req, reply) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(401).send({ error: 'no_token' });
    const token = auth.slice(7);

    let payload: any;
    try { payload = await app.jwt.verify(token); } catch { return reply.code(401).send({ error: 'invalid_token' }); }
    if (payload.type !== 'refresh') return reply.code(400).send({ error: 'not_refresh' });

    // vérifier existence (hash compare côté SQL)
    const ok = await app.db.any(
      `SELECT 1 FROM refresh_tokens
        WHERE user_id=$1 AND crypt($2, token_hash) = token_hash
          AND expires_at > NOW()`,
      [payload.sub, token]
    );
    if (!ok.length) return reply.code(401).send({ error: 'revoked' });

    const access = await app.jwt.sign({ }, { subject: payload.sub, expiresIn: '15m' });
    return reply.send({ access });
  });

  // GET /auth/me  (JWT access)
  app.get('/me', { onRequest: [app.authenticate] }, async (req, reply) => {
    const userId = (req.user as any).sub;
    const user = await app.db.one(
      `SELECT id, email, username, created_at FROM users WHERE id=$1`, [userId]
    );
    return user;
  });

  // POST /auth/logout  (révocation refresh courant)
  app.post('/logout', async (req, reply) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(400).send({ ok: true });
    const token = auth.slice(7);
    await app.db.none(`DELETE FROM refresh_tokens WHERE crypt($1, token_hash) = token_hash`, [token]);
    return { ok: true };
  });
}
