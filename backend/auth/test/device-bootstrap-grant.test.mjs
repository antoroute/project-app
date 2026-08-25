import assert from 'node:assert/strict';
import test from 'node:test';

import bcrypt from 'bcrypt';
import Fastify from 'fastify';

import authRoutes from '../dist/routes/auth.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const ACCOUNT = '11111111-1111-4111-8111-111111111111';
const PASSWORD = 'correct horse battery staple';

function claims() {
  const now = Math.floor(Date.now() / 1000);
  return {
    sub: ACCOUNT,
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    iat: now,
    exp: now + 900,
    jti: '22222222-2222-4222-8222-222222222222',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  };
}

async function bootstrapGrantApp({ grantLimitReached = false } = {}) {
  const passwordHash = await bcrypt.hash(PASSWORD, 4);
  const writes = [];
  const app = Fastify({ logger: false });
  app.decorate('authenticate', async (request) => {
    request.user = claims();
  });
  app.decorate('db', {
    one: async (query, params) => {
      if (query.includes('SELECT password FROM users')) {
        assert.deepEqual(params, [ACCOUNT]);
        return { password: passwordHash };
      }
      if (query.includes('INSERT INTO device_bootstrap_grants')) {
        if (grantLimitReached) throw new Error('No rows');
        writes.push({ query, params });
        return { id: '33333333-3333-4333-8333-333333333333' };
      }
      throw new Error('unexpected query');
    },
    any: async () => [],
    none: async () => undefined,
  });
  await app.register(authRoutes);
  await app.ready();
  return { app, writes };
}

test('une réauthentification délivre un grant court sans le stocker en clair', async (t) => {
  const { app, writes } = await bootstrapGrantApp();
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/device-bootstrap-grant',
    payload: { password: PASSWORD },
  });

  assert.equal(response.statusCode, 201);
  const body = response.json();
  assert.match(body.grant, /^[A-Za-z0-9_-]{43}$/);
  assert.ok(Date.parse(body.expiresAt) > Date.now());
  assert.equal(writes.length, 1);
  assert.match(writes[0].query, /INSERT INTO device_bootstrap_grants/);
  assert.equal(writes[0].params[0], ACCOUNT);
  assert.ok(Buffer.isBuffer(writes[0].params[1]));
  assert.equal(writes[0].params[1].length, 32);
  assert.notEqual(writes[0].params[1].toString('utf8'), body.grant);
});

test('un mot de passe incorrect ne délivre ni grant ni écriture', async (t) => {
  const { app, writes } = await bootstrapGrantApp();
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/device-bootstrap-grant',
    payload: { password: 'incorrect password' },
  });

  assert.equal(response.statusCode, 401);
  assert.equal(response.json().error, 'invalid_credentials');
  assert.equal(writes.length, 0);
});

test('la limite par compte refuse un nouveau grant après réauthentification', async (t) => {
  const { app, writes } = await bootstrapGrantApp({ grantLimitReached: true });
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/device-bootstrap-grant',
    payload: { password: PASSWORD },
  });

  assert.equal(response.statusCode, 429);
  assert.equal(response.json().error, 'too_many_bootstrap_grants');
  assert.equal(writes.length, 0);
});
