import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import fastifyJwt from '@fastify/jwt';
import Fastify from 'fastify';

import socketAuth from '../dist/middlewares/socketAuth.js';
import { createDeviceAccessTranscript } from '../dist/security/deviceAccess.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
  authenticatedUserId,
  registerAccessJwt,
  verifyAccessToken,
} from '../dist/security/jwt.js';

const ACCESS_KEYS = generateKeyPairSync('ed25519');
const REFRESH_SECRET = 'synthetic-refresh-secret-for-jwt-tests-00000000002';
const USER_ID = '11111111-1111-4111-8111-111111111111';
const JTI = '22222222-2222-4222-8222-222222222222';
const DEVICE_ID = '33333333-3333-4333-8333-333333333333';
const DEVICE_KEYS = generateKeyPairSync('ed25519');
const DEVICE_PUBLIC_KEY = Buffer.from(
  DEVICE_KEYS.publicKey.export({ format: 'der', type: 'spki' }),
).subarray(-32);

const ACCESS_PRIVATE_KEY = ACCESS_KEYS.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const ACCESS_PUBLIC_KEY = ACCESS_KEYS.publicKey.export({ type: 'spki', format: 'pem' }).toString();

async function accessApp() {
  const app = Fastify({ logger: false });
  await registerAccessJwt(app, ACCESS_PUBLIC_KEY);
  app.decorate('db', {
    oneOrNone: async () => ({
      identity_public_key: DEVICE_PUBLIC_KEY,
      identity_key_version: 1,
      status: 'active',
    }),
  });
  await app.ready();
  return app;
}

async function accessIssuer() {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, {
    secret: { private: ACCESS_PRIVATE_KEY, public: ACCESS_PUBLIC_KEY },
    sign: {
      algorithm: 'EdDSA',
      iss: JWT_ISSUER,
      aud: JWT_ACCESS_AUDIENCE,
      header: { alg: 'EdDSA', typ: 'JWT' },
      expiresIn: '15m',
    },
  });
  await app.ready();
  return app;
}

function payload(overrides = {}) {
  return { sub: USER_ID, jti: JTI, typ: 'access', ver: JWT_TOKEN_VERSION, ...overrides };
}

test('accepts a strict Ed25519 access token but cannot sign one', async (t) => {
  const app = await accessApp();
  const issuer = await accessIssuer();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const claims = verifyAccessToken(app, issuer.jwt.sign(payload()));
  assert.equal(claims.sub, USER_ID);
  assert.equal(claims.iss, JWT_ISSUER);
  assert.equal(claims.aud, JWT_ACCESS_AUDIENCE);
  assert.equal(authenticatedUserId({ user: claims }), USER_ID);
  assert.throws(() => authenticatedUserId({ user: { sub: USER_ID } }), /Invalid token claims/);
  assert.throws(() => app.jwt.sign(payload()), /unable to sign/);
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
      expiresIn: '30d',
    },
  });
  await issuer.ready();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  assert.throws(() => verifyAccessToken(app, issuer.jwt.sign(payload({ typ: 'refresh' }))));
});

test('rejects malformed claims and temporal bounds', async (t) => {
  const app = await accessApp();
  const issuer = await accessIssuer();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const signRaw = (claims, overrides = {}) => issuer.jwt.sign(claims, {
    algorithm: 'EdDSA',
    header: { alg: 'EdDSA', typ: 'JWT' },
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    expiresIn: '15m',
    ...overrides,
  });
  const cases = [
    signRaw(payload({ typ: 'refresh' })),
    signRaw(payload({ ver: 2 })),
    issuer.jwt.sign(
      { ...payload(), exp: Math.floor(Date.now() / 1000) - 1 },
      {
        algorithm: 'EdDSA',
        header: { alg: 'EdDSA', typ: 'JWT' },
        iss: JWT_ISSUER,
        aud: JWT_ACCESS_AUDIENCE,
      },
    ),
    signRaw(payload(), { notBefore: '1h' }),
    signRaw(payload(), { aud: 'wrong-audience' }),
  ];

  for (const token of cases) assert.throws(() => verifyAccessToken(app, token));
});

test('Socket.IO accepts access and rejects refresh tokens', async (t) => {
  const app = await accessApp();
  const issuer = await accessIssuer();
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
    await issuer.close();
    await refreshIssuer.close();
  });

  const access = issuer.jwt.sign(payload());
  const refresh = refreshIssuer.jwt.sign(payload({ typ: 'refresh' }));
  const authenticate = socketAuth(app, 'synthetic-app-secret-for-socket-test-000000000001');

  async function authenticateToken(token, includeDeviceProof = true) {
    const deviceProof = sign(
      null,
      createDeviceAccessTranscript({
        accountId: USER_ID,
        deviceId: DEVICE_ID,
        identityKeyVersion: 1,
        accessTokenId: JTI,
      }),
      DEVICE_KEYS.privateKey,
    ).toString('base64');
    const socket = {
      id: 'synthetic-socket',
      handshake: {
        address: '127.0.0.1',
        auth: {
          token,
          ...(includeDeviceProof
            ? {
                deviceId: DEVICE_ID,
                deviceKeyVersion: 1,
                deviceProof,
              }
            : {}),
        },
        headers: { 'x-app-secret': 'synthetic-app-secret-for-socket-test-000000000001' },
      },
    };
    const error = await new Promise((resolve) => authenticate(socket, resolve));
    return { socket, error };
  }

  const accepted = await authenticateToken(access);
  assert.equal(accepted.error, undefined);
  assert.deepEqual(accepted.socket.auth, {
    userId: USER_ID,
    deviceId: DEVICE_ID,
    identityKeyVersion: 1,
  });

  const missingDevice = await authenticateToken(access, false);
  assert.match(missingDevice.error.message, /device authorization required/);

  const rejected = await authenticateToken(refresh);
  assert.match(rejected.error.message, /invalid token/);
  assert.equal(rejected.socket.auth, undefined);
});

test('Ed25519 verification stays below the local latency budget', async (t) => {
  const app = await accessApp();
  const issuer = await accessIssuer();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });
  const token = issuer.jwt.sign(payload());
  for (let index = 0; index < 100; index += 1) verifyAccessToken(app, token);

  const iterations = 2_000;
  const startedAt = performance.now();
  for (let index = 0; index < iterations; index += 1) verifyAccessToken(app, token);
  const averageMilliseconds = (performance.now() - startedAt) / iterations;

  t.diagnostic(`average Ed25519 verification: ${averageMilliseconds.toFixed(4)} ms`);
  assert.ok(averageMilliseconds < 2, `average verification took ${averageMilliseconds} ms`);
});
