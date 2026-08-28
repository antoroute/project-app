import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import conversationsRoutes from '../dist/routes/conversations.js';
import groupsRoutes from '../dist/routes/groups.js';
import keysDevicesRoutes from '../dist/routes/keys.devices.js';
import messagesV2Routes from '../dist/routes/messages.v2.js';
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

async function routeApp(routes, aclOverrides = {}) {
  const calls = { db: 0, emissions: 0, transactions: 0 };
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
      hasGroupPermission: async () => false,
      hasConversationPermission: async () => false,
      canCreateConversation: async () => false,
      ...aclOverrides,
    },
  });
  const unexpectedDbCall = async () => {
    calls.db += 1;
    throw new Error('database must not be reached after an ACL refusal');
  };
  const transactionExecutor = {
    query: unexpectedDbCall,
    one: unexpectedDbCall,
    oneOrNone: unexpectedDbCall,
    any: unexpectedDbCall,
    none: unexpectedDbCall,
  };
  app.decorate('db', {
    ...transactionExecutor,
    transaction: async (work) => {
      calls.transactions += 1;
      return work(transactionExecutor);
    },
  });
  app.decorate('io', {
    in: () => ({ socketsJoin: () => undefined }),
    to: () => ({
      except: () => ({
        emit: () => {
          calls.emissions += 1;
        },
      }),
      emit: () => {
        calls.emissions += 1;
      },
    }),
  });
  await app.register(routes);
  await app.ready();
  return { app, calls };
}

test('un non-membre ne peut pas lire l’annuaire de clés du cercle', async (t) => {
  const { app, calls } = await routeApp(keysDevicesRoutes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'GET',
    url: `/api/keys/group/${GROUP}`,
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
});

test('une conversation avec participant extérieur est refusée avant écriture', async (t) => {
  const { app, calls } = await routeApp(conversationsRoutes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/api/conversations',
    payload: { groupId: GROUP, type: 'private', memberIds: [MEMBER] },
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
  assert.equal(calls.emissions, 0);
});

test('un membre simple ne peut pas voir les demandes d’adhésion', async (t) => {
  const { app, calls } = await routeApp(groupsRoutes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'GET',
    url: `/api/groups/${GROUP}/join-requests`,
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
});

test('la route de vote héritée est neutralisée sans écriture', async (t) => {
  const { app, calls } = await routeApp(groupsRoutes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: `/api/groups/${GROUP}/join-requests/${REQUEST}/vote`,
    payload: { vote: true },
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
});

test('un non-propriétaire ne peut pas affecter un rôle', async (t) => {
  const { app, calls } = await routeApp(groupsRoutes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'PATCH',
    url: `/api/groups/${GROUP}/members/${MEMBER}/role`,
    payload: { role: 'admin' },
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
});

test('une conversation inaccessible ne livre aucun message', async (t) => {
  const { app, calls } = await routeApp(messagesV2Routes);
  t.after(() => app.close());

  const response = await app.inject({
    method: 'GET',
    url: `/api/conversations/${CONVERSATION}/messages`,
  });

  assert.equal(response.statusCode, 403);
  assert.deepEqual(response.json(), { error: 'forbidden' });
  assert.equal(calls.db, 0);
});
