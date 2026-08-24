import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';

import fastifyJwt from '@fastify/jwt';
import Fastify from 'fastify';

import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_REFRESH_AUDIENCE,
  JWT_TOKEN_VERSION,
  authenticatedUserId,
  registerJwt,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
  verifyRefreshToken,
} from '../dist/security/jwt.js';

const ACCESS_KEYS = generateKeyPairSync('ed25519');
const REFRESH_SECRET = 'synthetic-refresh-secret-for-jwt-tests-00000000002';
const USER_ID = '11111111-1111-4111-8111-111111111111';
const JTI = '22222222-2222-4222-8222-222222222222';

function privatePem(keys = ACCESS_KEYS) {
  return keys.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
}

function publicPem(keys = ACCESS_KEYS) {
  return keys.publicKey.export({ type: 'spki', format: 'pem' }).toString();
}

async function jwtApp(keys = ACCESS_KEYS) {
  const app = Fastify({ logger: false });
  await registerJwt(app, privatePem(keys), publicPem(keys), REFRESH_SECRET);
  await app.ready();
  return app;
}

function accessPayload(overrides = {}) {
  return { sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION, ...overrides };
}

function signRawAccess(app, payload, overrides = {}) {
  return app.jwt.sign(payload, {
    algorithm: 'EdDSA',
    header: { alg: 'EdDSA', typ: 'JWT' },
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    expiresIn: '15m',
    ...overrides,
  });
}

test('issues strict Ed25519 access and independent HS256 refresh tokens', async (t) => {
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
  assert.equal(decodedAccess.header.alg, 'EdDSA');
  assert.equal(decodedAccess.header.typ, 'JWT');
  assert.equal(authenticatedUserId({ user: accessClaims }), USER_ID);
  assert.throws(() => authenticatedUserId({ user: { sub: USER_ID } }), /Invalid token claims/);
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
  const hsIssuer = Fastify({ logger: false });
  await hsIssuer.register(fastifyJwt, {
    secret: 'synthetic-hs-access-key-that-must-be-rejected-000001',
    sign: {
      algorithm: 'HS256',
      header: { alg: 'HS256', typ: 'JWT' },
      iss: JWT_ISSUER,
      aud: JWT_ACCESS_AUDIENCE,
      expiresIn: '15m',
    },
  });
  await hsIssuer.ready();
  t.after(async () => {
    await app.close();
    await hsIssuer.close();
  });

  const cases = [
    hsIssuer.jwt.sign(accessPayload()),
    signRawAccess(app, accessPayload(), { header: { alg: 'EdDSA', typ: 'NOT-JWT' } }),
    app.jwt.sign(
      { ...accessPayload(), exp: Math.floor(Date.now() / 1000) - 1 },
      {
        algorithm: 'EdDSA',
        header: { alg: 'EdDSA', typ: 'JWT' },
        iss: JWT_ISSUER,
        aud: JWT_ACCESS_AUDIENCE,
      },
    ),
    signRawAccess(app, accessPayload(), { notBefore: '1h' }),
  ];

  for (const token of cases) assert.throws(() => verifyAccessToken(app, token));
});

test('rejects a token signed with another Ed25519 private key', async (t) => {
  const app = await jwtApp();
  const foreign = await jwtApp(generateKeyPairSync('ed25519'));
  t.after(async () => {
    await app.close();
    await foreign.close();
  });

  assert.throws(() => verifyAccessToken(app, signAccessToken(foreign, USER_ID)));
});

test('Ed25519 signing and verification stay below the local latency budget', async (t) => {
  const app = await jwtApp();
  t.after(() => app.close());
  const token = signAccessToken(app, USER_ID);
  for (let index = 0; index < 100; index += 1) verifyAccessToken(app, token);

  const iterations = 2_000;
  const signingStartedAt = performance.now();
  for (let index = 0; index < iterations; index += 1) signAccessToken(app, USER_ID);
  const averageSigningMilliseconds = (performance.now() - signingStartedAt) / iterations;
  const verificationStartedAt = performance.now();
  for (let index = 0; index < iterations; index += 1) verifyAccessToken(app, token);
  const averageVerificationMilliseconds = (performance.now() - verificationStartedAt) / iterations;

  t.diagnostic(`average Ed25519 signing: ${averageSigningMilliseconds.toFixed(4)} ms`);
  t.diagnostic(`average Ed25519 verification: ${averageVerificationMilliseconds.toFixed(4)} ms`);
  assert.ok(averageSigningMilliseconds < 2, `average signing took ${averageSigningMilliseconds} ms`);
  assert.ok(
    averageVerificationMilliseconds < 2,
    `average verification took ${averageVerificationMilliseconds} ms`,
  );
});
