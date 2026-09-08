import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import conversationsRoutes from '../dist/routes/conversations.js';
import messagesV2Routes from '../dist/routes/messages.v2.js';
import {
  MAX_SOCKET_BATCH_CONVERSATIONS,
  MESSAGING_BODY_LIMIT_BYTES,
  parseStrictConversationBatch,
  parseStrictConversationEvent,
} from '../dist/schemas/input.schema.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const USER_ID = '11111111-1111-4111-8111-111111111111';
const DEVICE_ID = '22222222-2222-4222-8222-222222222222';
const OTHER_USER_ID = '33333333-3333-4333-8333-333333333333';
const OTHER_DEVICE_ID = '44444444-4444-4444-8444-444444444444';
const GROUP_ID = '55555555-5555-4555-8555-555555555555';
const CONVERSATION_ID = '66666666-6666-4666-8666-666666666666';
const MESSAGE_ID = '77777777-7777-4777-8777-777777777777';
const KEY_32_B64 = Buffer.alloc(32).toString('base64');
const NONCE_12_B64 = Buffer.alloc(12).toString('base64');
const WRAP_48_B64 = Buffer.alloc(48).toString('base64');
const SIGNATURE_64_B64 = Buffer.alloc(64).toString('base64');
const CIPHERTEXT_16_B64 = Buffer.alloc(16).toString('base64');

function claims() {
  const now = Math.floor(Date.now() / 1000);
  return {
    sub: USER_ID,
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    iat: now,
    exp: now + 900,
    jti: '88888888-8888-4888-8888-888888888888',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  };
}

function validMessage() {
  return {
    v: 2,
    alg: { kem: 'X25519', kdf: 'HKDF-SHA256', aead: 'AES-256-GCM', sig: 'Ed25519' },
    groupId: GROUP_ID,
    convId: CONVERSATION_ID,
    messageId: MESSAGE_ID,
    sentAt: Math.floor(Date.now() / 1000),
    sender: { userId: USER_ID, deviceId: DEVICE_ID, eph_pub: KEY_32_B64, key_version: 1 },
    recipients: [{
      userId: OTHER_USER_ID,
      deviceId: OTHER_DEVICE_ID,
      key_version: 1,
      wrap: WRAP_48_B64,
      nonce: NONCE_12_B64,
    }],
    iv: NONCE_12_B64,
    ciphertext: CIPHERTEXT_16_B64,
    sig: SIGNATURE_64_B64,
    salt: KEY_32_B64,
  };
}

async function validationApp() {
  const calls = { transactions: 0, any: [] };
  const app = Fastify({
    logger: false,
    bodyLimit: MESSAGING_BODY_LIMIT_BYTES,
    ajv: { customOptions: { removeAdditional: false } },
  });
  app.decorate('authenticate', async (request) => {
    request.user = claims();
  });
  app.decorateRequest('accountDevice', null);
  app.decorate('requireActiveDevice', async (request) => {
    request.accountDevice = {
      deviceId: DEVICE_ID,
      identityKeyVersion: 1,
      identityPublicKey: Buffer.alloc(32),
      status: 'active',
    };
  });
  app.decorate('services', {
    acl: {
      canSend: async () => true,
      canCreateConversation: async () => true,
      hasConversationPermission: async () => true,
    },
  });
  app.decorate('db', {
    transaction: async () => {
      calls.transactions += 1;
      throw new Error('transaction must not be reached');
    },
    any: async (_query, params) => {
      calls.any.push(params);
      return [];
    },
  });
  app.decorate('io', {
    to: () => ({ except: () => ({ emit: () => undefined }) }),
    in: () => ({ socketsJoin: () => undefined }),
  });
  await app.register(messagesV2Routes);
  await app.register(conversationsRoutes);
  await app.ready();
  return { app, calls };
}

test('les événements Socket.IO sont stricts, bornés et sans doublons', () => {
  assert.equal(parseStrictConversationEvent({ convId: CONVERSATION_ID }), CONVERSATION_ID);
  assert.equal(parseStrictConversationEvent(CONVERSATION_ID), null);
  assert.equal(parseStrictConversationEvent({ convId: CONVERSATION_ID, extra: true }), null);
  assert.equal(parseStrictConversationEvent({ convId: 'invalid' }), null);

  const uniqueIds = Array.from(
    { length: MAX_SOCKET_BATCH_CONVERSATIONS },
    (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
  );
  assert.deepEqual(parseStrictConversationBatch({ convIds: uniqueIds }), uniqueIds);
  assert.equal(parseStrictConversationBatch({ convIds: [] }), null);
  assert.equal(parseStrictConversationBatch({ convIds: [...uniqueIds, CONVERSATION_ID] }), null);
  assert.equal(parseStrictConversationBatch({ convIds: [CONVERSATION_ID, CONVERSATION_ID] }), null);
  assert.equal(parseStrictConversationBatch({ convIds: [CONVERSATION_ID], extra: true }), null);
});

test('refuse les enveloppes de message inconnues, mal formées ou trop larges avant écriture', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());

  const unknown = { ...validMessage(), unexpected: true };
  const badKey = validMessage();
  badKey.sender.eph_pub = 'AA==';
  const tooManyRecipients = validMessage();
  tooManyRecipients.recipients = Array.from({ length: 257 }, (_, index) => ({
    ...tooManyRecipients.recipients[0],
    deviceId: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
  }));
  const decodedCiphertextTooLarge = validMessage();
  decodedCiphertextTooLarge.ciphertext = Buffer.alloc(65538).toString('base64');

  for (const payload of [
    unknown,
    badKey,
    tooManyRecipients,
    decodedCiphertextTooLarge,
  ]) {
    const response = await app.inject({ method: 'POST', url: '/api/messages', payload });
    assert.equal(response.statusCode, 400);
  }
  assert.equal(calls.transactions, 0);
});

test('refuse explicitement un destinataire chiffré dupliqué avant écriture', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());
  const payload = validMessage();
  payload.recipients.push({ ...payload.recipients[0] });

  const response = await app.inject({ method: 'POST', url: '/api/messages', payload });

  assert.equal(response.statusCode, 400);
  assert.deepEqual(response.json(), { error: 'duplicate_recipient' });
  assert.equal(calls.transactions, 0);
});

test('refuse les listes de participants trop longues ou dupliquées avant écriture', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());
  const members = Array.from(
    { length: 128 },
    (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
  );

  for (const memberIds of [members, [OTHER_USER_ID, OTHER_USER_ID]]) {
    const response = await app.inject({
      method: 'POST',
      url: '/api/conversations',
      payload: { groupId: GROUP_ID, type: 'private', memberIds },
    });
    assert.equal(response.statusCode, 400);
  }
  assert.equal(calls.transactions, 0);
});

test('interprète le curseur paginé en secondes et borne la page à 100', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());
  const cursorSeconds = 1_700_000_000;

  const response = await app.inject({
    method: 'GET',
    url: `/api/conversations/${CONVERSATION_ID}/messages?cursor=${cursorSeconds}&limit=100`,
  });

  assert.equal(response.statusCode, 200);
  assert.equal(calls.any.length, 1);
  assert.equal(calls.any[0][1].getTime(), cursorSeconds * 1000);
  assert.equal(calls.any[0][2], 100);

  const oversizedPage = await app.inject({
    method: 'GET',
    url: `/api/conversations/${CONVERSATION_ID}/messages?limit=101`,
  });
  assert.equal(oversizedPage.statusCode, 400);
});

test('borne le corps HTTP messaging à 256 Kio', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/api/messages',
    headers: { 'content-type': 'application/json' },
    payload: JSON.stringify({ oversized: 'a'.repeat(MESSAGING_BODY_LIMIT_BYTES) }),
  });

  assert.equal(response.statusCode, 413);
  assert.equal(calls.transactions, 0);
});
