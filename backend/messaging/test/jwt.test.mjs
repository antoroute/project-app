import assert from 'node:assert/strict';
import test from 'node:test';

import fastifyJwt from '@fastify/jwt';
import Fastify from 'fastify';

import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
  registerAccessJwt,
  verifyAccessToken,
} from '../dist/security/jwt.js';
import socketAuth from '../dist/middlewares/socketAuth.js';

const ACCESS_SECRET = 'synthetic-access-secret-for-jwt-tests-000000000001';
const REFRESH_SECRET = 'synthetic-refresh-secret-for-jwt-tests-00000000002';
const USER_ID = '11111111-1111-4111-8111-111111111111';
const JTI = '22222222-2222-4222-8222-222222222222';

async function accessApp() {
  const app = Fastify({ logger: false });
  await registerAccessJwt(app, ACCESS_SECRET);
  await app.ready();
  return app;
}

test('accepts only a strict access token', async (t) => {
  const app = await accessApp();
  t.after(() => app.close());

  const token = app.jwt.sign(
    { sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION },
  );
  const claims = verifyAccessToken(app, token);
  assert.equal(claims.sub, USER_ID);
  assert.equal(claims.iss, JWT_ISSUER);
  assert.equal(claims.aud, JWT_ACCESS_AUDIENCE);
});

test('rejects a refresh token even when its claims are otherwise complete', async (t) => {
  const app = await accessApp();
  const issuer = Fastify({ logger: false });
  await issuer.register(fastifyJwt, {
    secret: REFRESH_SECRET,
    sign: {
      algorithm: 'HS256',
      iss: JWT_ISSUER,
      aud: 'trust-circle-auth',
      header: { alg: 'HS256', typ: 'JWT' },
    },
  });
  await issuer.ready();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const refresh = issuer.jwt.sign(
    { sub: USER_ID, jti: JTI, typ: 'refresh', ver: JWT_TOKEN_VERSION },
    { expiresIn: '30d' },
  );
  assert.throws(() => verifyAccessToken(app, refresh));
});

test('rejects malformed claims and temporal bounds', async (t) => {
  const app = await accessApp();
  t.after(() => app.close());

  const payload = { sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION };
  const signRaw = (claims, overrides = {}) => app.jwt.sign(claims, {
    algorithm: 'HS256',
    header: { alg: 'HS256', typ: 'JWT' },
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    expiresIn: '15m',
    ...overrides,
  });
  const cases = [
    signRaw({ ...payload, typ: 'refresh' }),
    signRaw({ ...payload, ver: 2 }),
    app.jwt.sign(
      { ...payload, exp: Math.floor(Date.now() / 1000) - 1 },
      {
        algorithm: 'HS256',
        header: { alg: 'HS256', typ: 'JWT' },
        iss: JWT_ISSUER,
        aud: JWT_ACCESS_AUDIENCE,
      },
    ),
    signRaw(payload, { notBefore: '1h' }),
    signRaw(payload, { aud: 'wrong-audience' }),
  ];

  for (const token of cases) assert.throws(() => verifyAccessToken(app, token));
});

test('Socket.IO accepts access and rejects refresh tokens', async (t) => {
  const app = await accessApp();
  const refreshIssuer = Fastify({ logger: false });
  await refreshIssuer.register(fastifyJwt, {
    secret: REFRESH_SECRET,
    sign: {
      algorithm: 'HS256',
      iss: JWT_ISSUER,
      aud: 'trust-circle-auth',
      header: { alg: 'HS256', typ: 'JWT' },
      expiresIn: '30d',
    },
  });
  await refreshIssuer.ready();
  t.after(async () => {
    await app.close();
    await refreshIssuer.close();
  });

  const access = app.jwt.sign({ sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION });
  const refresh = refreshIssuer.jwt.sign({
    sub: USER_ID,
    jti: JTI,
    typ: 'refresh',
    ver: JWT_TOKEN_VERSION,
  });
  const authenticate = socketAuth(app, 'synthetic-app-secret-for-socket-test-000000000001');

  async function authenticateToken(token) {
    const socket = {
      id: 'synthetic-socket',
      handshake: {
        address: '127.0.0.1',
        auth: { token },
        headers: { 'x-app-secret': 'synthetic-app-secret-for-socket-test-000000000001' },
      },
    };
    const error = await new Promise((resolve) => authenticate(socket, resolve));
    return { socket, error };
  }

  const accepted = await authenticateToken(access);
  assert.equal(accepted.error, undefined);
  assert.deepEqual(accepted.socket.auth, { userId: USER_ID });

  const rejected = await authenticateToken(refresh);
  assert.match(rejected.error.message, /invalid token/);
  assert.equal(rejected.socket.auth, undefined);
});
