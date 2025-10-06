import { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { Type } from '@sinclair/typebox';
import bcrypt from 'bcrypt';

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

    // NOTE: 'sub' et 'iss' dans le payload – pas dans les options.
    const access = await app.jwt.sign(
      { sub: row.id, iss: 'project-app', aud: 'messaging' },
      { expiresIn: '15m' }
    );
    const refresh = await app.jwt.sign(
      { sub: row.id, iss: 'project-app', aud: 'messaging', typ: 'refresh' },
      { expiresIn: '30d' }
    );

    await app.db.none(
      `INSERT INTO refresh_tokens(user_id, token_hash, expires_at)
       VALUES($1, crypt($2, gen_salt('bf')), NOW() + interval '30 days')`,
      [row.id, refresh]
    );

    return reply.send({ access, refresh, user: { id: row.id, email: row.email, username: row.username } });
  });

  app.post('/refresh', {}, async (req: FastifyRequest, reply: FastifyReply) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(401).send({ error: 'no_token' });
    const token = auth.slice(7);

    let payload: any;
    try { payload = await app.jwt.verify(token); }
    catch { return reply.code(401).send({ error: 'invalid_token' }); }
    if (payload.typ !== 'refresh') return reply.code(400).send({ error: 'not_refresh' });

    const ok = await app.db.any(
      `SELECT 1 FROM refresh_tokens
        WHERE user_id=$1 AND crypt($2, token_hash) = token_hash
          AND expires_at > NOW()`,
      [payload.sub, token]
    );
    if (!ok.length) return reply.code(401).send({ error: 'revoked' });

    const accessToken = await app.jwt.sign(
      { sub: payload.sub, iss: 'project-app', aud: 'messaging' },
      { expiresIn: '15m' }
    );
    return reply.send({ accessToken });
  });

  app.get('/me', { onRequest: [app.authenticate] }, async (req: FastifyRequest, reply: FastifyReply) => {
    const userId = (req.user as any).sub;
    const user = await app.db.one(`SELECT id, email, username, created_at FROM users WHERE id=$1`, [userId]);
    return user;
  });

  app.post('/logout', {}, async (req: FastifyRequest, reply: FastifyReply) => {
    const auth = req.headers.authorization;
    if (!auth?.startsWith('Bearer ')) return reply.code(200).send({ ok: true });
    const token = auth.slice(7);
    await app.db.none(`DELETE FROM refresh_tokens WHERE crypt($1, token_hash) = token_hash`, [token]);
    return { ok: true };
  });
}
