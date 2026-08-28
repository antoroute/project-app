import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';

import fastifyJwt from '@fastify/jwt';
import Fastify from 'fastify';

import messagesV2Routes from '../dist/routes/messages.v2.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
  assertAccessClaims,
  registerAccessJwt,
} from '../dist/security/jwt.js';

const AUTHENTICATED_USER_ID = '11111111-1111-4111-8111-111111111111';
const FORGED_USER_ID = '22222222-2222-4222-8222-222222222222';
const CONVERSATION_ID = '33333333-3333-4333-8333-333333333333';
const GROUP_ID = '44444444-4444-4444-8444-444444444444';
const MESSAGE_ID = '55555555-5555-4555-8555-555555555555';
const STORED_MESSAGE_ID = '66666666-6666-4666-8666-666666666666';
const SENDER_DEVICE_ID = '88888888-8888-4888-8888-888888888888';
const RECIPIENT_DEVICE_ID = '99999999-9999-4999-8999-999999999999';

const ACCESS_KEYS = generateKeyPairSync('ed25519');
const ACCESS_PRIVATE_KEY = ACCESS_KEYS.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const ACCESS_PUBLIC_KEY = ACCESS_KEYS.publicKey.export({ type: 'spki', format: 'pem' }).toString();

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

async function messageApp({ insertError = null } = {}) {
  const calls = { acl: [], inserts: [], emissions: [], sequence: [] };
  const app = Fastify({ logger: false });
  await registerAccessJwt(app, ACCESS_PUBLIC_KEY);
  app.decorate('authenticate', async (request, reply) => {
    try {
      request.user = assertAccessClaims(await request.jwtVerify());
    } catch {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });
  app.decorateRequest('accountDevice', null);
  app.decorate('requireActiveDevice', async (request) => {
    request.accountDevice = {
      deviceId: SENDER_DEVICE_ID,
      identityKeyVersion: 1,
      identityPublicKey: Buffer.alloc(32),
      status: 'active',
    };
  });
  app.decorate('services', {
    acl: {
      canSend: async (...args) => {
        calls.acl.push(args);
        return true;
      },
    },
  });
  const transactionExecutor = {
    one: async (query, params) => {
      calls.sequence.push('insert');
      calls.inserts.push({ query, params });
      if (insertError) throw insertError;
      return { id: STORED_MESSAGE_ID };
    },
  };
  app.decorate('db', {
    transaction: async (work) => {
      calls.sequence.push('begin');
      try {
        const result = await work(transactionExecutor);
        calls.sequence.push('commit');
        return result;
      } catch (error) {
        calls.sequence.push('rollback');
        throw error;
      }
    },
  });
  app.decorate('io', {
    to: (room) => ({
      except: (excludedRoom) => ({
        emit: (event, payload) => {
          calls.sequence.push('emit');
          calls.emissions.push({ room, excludedRoom, event, payload });
        },
      }),
    }),
  });
  await app.register(messagesV2Routes);
  await app.ready();
  return { app, calls };
}

function messagePayload(senderUserId) {
  return {
    v: 2,
    alg: { kem: 'X25519', kdf: 'HKDF-SHA256', aead: 'AES-256-GCM', sig: 'Ed25519' },
    groupId: GROUP_ID,
    convId: CONVERSATION_ID,
    messageId: MESSAGE_ID,
    sentAt: Math.floor(Date.now() / 1000),
    sender: { userId: senderUserId, deviceId: SENDER_DEVICE_ID, eph_pub: 'AA==', key_version: 1 },
    recipients: [{ userId: FORGED_USER_ID, deviceId: RECIPIENT_DEVICE_ID, key_version: 1, wrap: 'AA==', nonce: 'AA==' }],
    iv: 'AA==',
    ciphertext: 'AA==',
    sig: 'AA==',
    salt: 'AA==',
  };
}

function accessToken(issuer) {
  return issuer.jwt.sign({
    sub: AUTHENTICATED_USER_ID,
    jti: '77777777-7777-4777-8777-777777777777',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  });
}

test('rejects a forged sender identity before ACL, database and Socket.IO', async (t) => {
  const issuer = await accessIssuer();
  const { app, calls } = await messageApp();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const response = await app.inject({
    method: 'POST',
    url: '/api/messages',
    headers: { authorization: `Bearer ${accessToken(issuer)}` },
    payload: messagePayload(FORGED_USER_ID),
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.acl.length, 0);
  assert.equal(calls.inserts.length, 0);
  assert.equal(calls.emissions.length, 0);
});

test('uses only the authenticated subject for ACL, persistence and sender room', async (t) => {
  const issuer = await accessIssuer();
  const { app, calls } = await messageApp();
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const response = await app.inject({
    method: 'POST',
    url: '/api/messages',
    headers: { authorization: `Bearer ${accessToken(issuer)}` },
    payload: messagePayload(AUTHENTICATED_USER_ID),
  });

  assert.equal(response.statusCode, 201);
  assert.deepEqual(response.json(), { id: STORED_MESSAGE_ID });
  assert.equal(calls.acl.length, 1);
  assert.equal(calls.acl[0][0], AUTHENTICATED_USER_ID);
  assert.equal(calls.inserts.length, 1);
  assert.equal(calls.inserts[0].params[1], AUTHENTICATED_USER_ID);
  assert.equal(calls.emissions.length, 1);
  assert.equal(calls.emissions[0].excludedRoom, `user:${AUTHENTICATED_USER_ID}`);
  assert.deepEqual(calls.sequence, ['begin', 'insert', 'commit', 'emit']);
  assert.equal(calls.acl[0][2], 1);
  assert.equal(calls.acl[0][6].lock, true);
  assert.ok(calls.acl[0][6].executor);
});

test('un rollback de persistance ne produit aucun événement Socket.IO', async (t) => {
  const issuer = await accessIssuer();
  const insertError = new Error('synthetic insert failure');
  const { app, calls } = await messageApp({ insertError });
  t.after(async () => {
    await app.close();
    await issuer.close();
  });

  const response = await app.inject({
    method: 'POST',
    url: '/api/messages',
    headers: { authorization: `Bearer ${accessToken(issuer)}` },
    payload: messagePayload(AUTHENTICATED_USER_ID),
  });

  assert.equal(response.statusCode, 500);
  assert.deepEqual(calls.sequence, ['begin', 'insert', 'rollback']);
  assert.equal(calls.emissions.length, 0);
});
