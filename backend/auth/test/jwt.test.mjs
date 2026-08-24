import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_REFRESH_AUDIENCE,
  JWT_TOKEN_VERSION,
  registerJwt,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
  verifyRefreshToken,
} from '../dist/security/jwt.js';

const ACCESS_SECRET = 'synthetic-access-secret-for-jwt-tests-000000000001';
const REFRESH_SECRET = 'synthetic-refresh-secret-for-jwt-tests-00000000002';
const USER_ID = '11111111-1111-4111-8111-111111111111';
const JTI = '22222222-2222-4222-8222-222222222222';

async function jwtApp(accessSecret = ACCESS_SECRET, refreshSecret = REFRESH_SECRET) {
  const app = Fastify({ logger: false });
  await registerJwt(app, accessSecret, refreshSecret);
  await app.ready();
  return app;
}

function accessPayload(overrides = {}) {
  return { sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION, ...overrides };
}

function signRawAccess(app, payload, overrides = {}) {
  return app.jwt.sign(payload, {
    algorithm: 'HS256',
    header: { alg: 'HS256', typ: 'JWT' },
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    expiresIn: '15m',
    ...overrides,
  });
}

test('issues strict, distinct access and refresh tokens', async (t) => {
  const app = await jwtApp();
  t.after(() => app.close());

  const access = signAccessToken(app, USER_ID);
  const refresh = signRefreshToken(app, USER_ID);
  const accessClaims = verifyAccessToken(app, access);
  const refreshClaims = verifyRefreshToken(app, refresh);
  const decodedAccess = app.jwt.decode(access, { complete: true });

  assert.equal(accessClaims.typ, 'access');
  assert.equal(accessClaims.iss, JWT_ISSUER);
  assert.equal(accessClaims.aud, JWT_ACCESS_AUDIENCE);
  assert.equal(accessClaims.ver, JWT_TOKEN_VERSION);
  assert.equal(refreshClaims.typ, 'refresh');
  assert.equal(refreshClaims.aud, JWT_REFRESH_AUDIENCE);
  assert.notEqual(accessClaims.jti, refreshClaims.jti);
  assert.equal(decodedAccess.header.alg, 'HS256');
  assert.equal(decodedAccess.header.typ, 'JWT');
});

test('rejects refresh as access and access as refresh', async (t) => {
  const app = await jwtApp();
  t.after(() => app.close());

  const access = signAccessToken(app, USER_ID);
  const refresh = signRefreshToken(app, USER_ID);
  assert.throws(() => verifyAccessToken(app, refresh));
  assert.throws(() => verifyRefreshToken(app, access));
});

test('rejects wrong issuer, audience, type, version and required claims', async (t) => {
  const app = await jwtApp();
  t.after(() => app.close());

  const cases = [
    signRawAccess(app, accessPayload(), { iss: 'wrong-issuer' }),
    signRawAccess(app, accessPayload(), { aud: 'wrong-audience' }),
    signRawAccess(app, accessPayload({ typ: 'refresh' })),
    signRawAccess(app, accessPayload({ ver: 2 })),
    signRawAccess(app, { sub: USER_ID, typ: 'access', ver: 1 }),
  ];

  for (const token of cases) assert.throws(() => verifyAccessToken(app, token));
});

test('rejects wrong algorithm, header type, expiration and future nbf', async (t) => {
  const app = await jwtApp();
  t.after(() => app.close());

  const cases = [
    signRawAccess(app, accessPayload(), {
      algorithm: 'HS384',
      header: { alg: 'HS384', typ: 'JWT' },
    }),
    signRawAccess(app, accessPayload(), {
      header: { alg: 'HS256', typ: 'NOT-JWT' },
    }),
    app.jwt.sign(
      { ...accessPayload(), exp: Math.floor(Date.now() / 1000) - 1 },
      {
        algorithm: 'HS256',
        header: { alg: 'HS256', typ: 'JWT' },
        iss: JWT_ISSUER,
        aud: JWT_ACCESS_AUDIENCE,
      },
    ),
    signRawAccess(app, accessPayload(), { notBefore: '1h' }),
  ];

  for (const token of cases) assert.throws(() => verifyAccessToken(app, token));
});

test('rejects a token signed with another access key', async (t) => {
  const app = await jwtApp();
  const foreign = await jwtApp('synthetic-foreign-access-secret-00000000000000001');
  t.after(async () => {
    await app.close();
    await foreign.close();
  });

  assert.throws(() => verifyAccessToken(app, signAccessToken(foreign, USER_ID)));
});
