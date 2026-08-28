import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import conversationsRoutes from '../dist/routes/conversations.js';
import groupsRoutes from '../dist/routes/groups.js';
import keysDevicesRoutes from '../dist/routes/keys.devices.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const ACTOR = '11111111-1111-4111-8111-111111111111';
const MEMBER = '22222222-2222-4222-8222-222222222222';
const GROUP = '33333333-3333-4333-8333-333333333333';
const CONVERSATION = '44444444-4444-4444-8444-444444444444';
const REQUEST = '55555555-5555-4555-8555-555555555555';
const DEVICE = '77777777-7777-4777-8777-777777777777';

function authenticatedClaims() {
  const now = Math.floor(Date.now() / 1000);
  return {
    sub: ACTOR,
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    iat: now,
    exp: now + 900,
    jti: '66666666-6666-4666-8666-666666666666',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  };
}

async function atomicApp(routes, executor, aclOverrides = {}) {
  const sequence = [];
  const app = Fastify({ logger: false });
  app.decorate('authenticate', async (request) => {
    request.user = authenticatedClaims();
  });
  app.decorateRequest('accountDevice', null);
  app.decorate('requireActiveDevice', async (request) => {
    request.accountDevice = {
      deviceId: DEVICE,
      identityKeyVersion: 1,
      identityPublicKey: Buffer.alloc(32),
      status: 'active',
    };
  });
  app.decorate('services', {
    acl: {
      hasGroupPermission: async () => true,
      hasConversationPermission: async () => true,
      canCreateConversation: async () => true,
      ...aclOverrides,
    },
    presence: {
      broadcastUserPresence: () => sequence.push('presence'),
    },
  });
  app.decorate('db', {
    transaction: async (work) => {
      sequence.push('begin');
      try {
        const result = await work(executor);
        sequence.push('commit');
        return result;
      } catch (error) {
        sequence.push('rollback');
        throw error;
      }
    },
  });
  app.decorate('io', {
    in: () => ({ socketsJoin: () => sequence.push('room') }),
    to: () => ({
      except: () => ({ emit: () => sequence.push('emit') }),
      emit: () => sequence.push('emit'),
    }),
  });
  await app.register(routes);
  await app.ready();
  return { app, sequence };
}

test('un échec de création de cercle rollback sans rejoindre de room', async (t) => {
  const failure = new Error('membership insert failed');
  const executor = {
    one: async () => ({ id: GROUP }),
    none: async () => { throw failure; },
  };
  const { app, sequence } = await atomicApp(groupsRoutes, executor);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/api/groups',
    payload: { name: 'Atomic group' },
  });

  assert.equal(response.statusCode, 500);
  assert.deepEqual(sequence, ['begin', 'rollback']);
});

test('un échec des participants rollback sans événement conversation', async (t) => {
  const executor = {
    one: async () => ({ id: CONVERSATION }),
    none: async () => { throw new Error('members insert failed'); },
  };
  const { app, sequence } = await atomicApp(conversationsRoutes, executor);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/api/conversations',
    payload: { groupId: GROUP, type: 'private', memberIds: [MEMBER] },
  });

  assert.equal(response.statusCode, 500);
  assert.deepEqual(sequence, ['begin', 'rollback']);
});

test('une acceptation échouée rollback sans notification ni room', async (t) => {
  let selects = 0;
  let writes = 0;
  const executor = {
    oneOrNone: async () => {
      selects += 1;
      if (selects === 1) return { id: GROUP };
      return {
        id: REQUEST,
        user_id: MEMBER,
        device_id: 'member-device',
        pk_sig: Buffer.alloc(32),
        pk_kem: Buffer.alloc(32),
      };
    },
    none: async () => {
      writes += 1;
      if (writes === 2) throw new Error('status update failed');
    },
  };
  const { app, sequence } = await atomicApp(groupsRoutes, executor);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: `/api/groups/${GROUP}/join-requests/${REQUEST}/handle`,
    payload: { action: 'accept' },
  });

  assert.equal(response.statusCode, 500);
  assert.deepEqual(sequence, ['begin', 'rollback']);
});

test('les notifications d’adhésion sont strictement postérieures au commit', async (t) => {
  let selects = 0;
  const executor = {
    oneOrNone: async () => {
      selects += 1;
      if (selects === 1) return { id: GROUP };
      return {
        id: REQUEST,
        user_id: MEMBER,
        device_id: 'member-device',
        pk_sig: Buffer.alloc(32),
        pk_kem: Buffer.alloc(32),
      };
    },
    none: async () => undefined,
  };
  const { app, sequence } = await atomicApp(groupsRoutes, executor);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: `/api/groups/${GROUP}/join-requests/${REQUEST}/handle`,
    payload: { action: 'accept' },
  });

  assert.equal(response.statusCode, 200);
  assert.equal(sequence[0], 'begin');
  assert.equal(sequence[1], 'commit');
  assert.deepEqual(sequence.slice(2), ['room', 'emit', 'emit', 'presence']);
});

test('la révocation historique par cercle exige la décision globale signée', async (t) => {
  const executor = {};
  const { app, sequence } = await atomicApp(keysDevicesRoutes, executor);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'DELETE',
    url: `/api/keys/group/${GROUP}/devices/${DEVICE}`,
  });

  assert.equal(response.statusCode, 409);
  assert.deepEqual(response.json().error, 'global_device_revocation_required');
  assert.deepEqual(sequence, []);
});
