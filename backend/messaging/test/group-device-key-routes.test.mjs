import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import Fastify from 'fastify';

import keysDevicesRoutes from '../dist/routes/keys.devices.js';
import { createGroupDeviceKeyTranscript } from '../dist/security/groupDeviceKeyBinding.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const ACCOUNT = '11111111-1111-4111-8111-111111111111';
const DEVICE = '22222222-2222-4222-8222-222222222222';
const GROUP = '33333333-3333-4333-8333-333333333333';

function claims() {
  const now = Math.floor(Date.now() / 1000);
  return {
    sub: ACCOUNT,
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    iat: now,
    exp: now + 900,
    jti: '44444444-4444-4444-8444-444444444444',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  };
}

function identity() {
  const keyPair = generateKeyPairSync('ed25519');
  const der = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  return { keyPair, publicKey: Buffer.from(der).subarray(-32) };
}

function normalized(query) {
  return query.replace(/\s+/g, ' ').trim();
}

function database(state) {
  let tail = Promise.resolve();
  const executor = {
    oneOrNone: async (query) => {
      const sql = normalized(query);
      if (sql.includes('FROM users WHERE id = $1 FOR UPDATE')) {
        return { id: ACCOUNT };
      }
      if (sql.includes('FROM account_devices')) {
        return {
          identity_public_key: state.identity.publicKey,
          identity_key_version: 1,
          status: state.deviceStatus,
        };
      }
      if (sql.includes('FROM group_device_keys')) return state.current;
      throw new Error(`unexpected query: ${sql}`);
    },
    none: async (query, params) => {
      const sql = normalized(query);
      if (sql.startsWith('INSERT INTO group_device_keys')) {
        state.current = {
          pk_sig: Buffer.from(params[3]),
          pk_kem: Buffer.from(params[4]),
          key_version: params[5],
          identity_key_version: params[6],
          binding_signature: Buffer.from(params[7]),
          status: 'active',
          created_at: new Date(),
        };
        return;
      }
      if (sql.startsWith('INSERT INTO group_device_key_history')) {
        state.history.push({
          keyVersion: params[3],
          pkSig: Buffer.from(params[5]),
          pkKem: Buffer.from(params[6]),
        });
        return;
      }
      if (sql.startsWith('UPDATE group_device_keys')) {
        if (params.length === 5) {
          state.current.identity_key_version = params[3];
          state.current.binding_signature = Buffer.from(params[4]);
          state.current.status = 'active';
          return;
        }
        state.current = {
          pk_sig: Buffer.from(params[3]),
          pk_kem: Buffer.from(params[4]),
          key_version: params[5],
          identity_key_version: params[6],
          binding_signature: Buffer.from(params[7]),
          status: 'active',
          created_at: new Date(),
        };
        return;
      }
      throw new Error(`unexpected write: ${sql}`);
    },
  };
  return {
    transaction: async (work) => {
      const run = tail.then(() => work(executor));
      tail = run.catch(() => undefined);
      return run;
    },
  };
}

async function appFor(state) {
  const app = Fastify({ logger: false });
  app.decorate('authenticate', async (request) => {
    request.user = claims();
  });
  app.decorateRequest('accountDevice', null);
  app.decorate('requireActiveDevice', async (request) => {
    request.accountDevice = {
      deviceId: DEVICE,
      identityKeyVersion: 1,
      identityPublicKey: state.identity.publicKey,
      status: 'active',
    };
  });
  app.decorate('services', {
    acl: { hasGroupPermission: async () => true },
  });
  app.decorate('io', {
    to: (room) => ({
      emit: (event, payload) => {
        state.directoryEvents.push({ room, event, payload });
      },
    }),
  });
  app.decorate('db', database(state));
  await app.register(keysDevicesRoutes);
  await app.ready();
  return app;
}

function publication(state, keyVersion, marker = keyVersion) {
  const pkSig = Buffer.alloc(32, marker);
  const pkKem = Buffer.alloc(32, marker + 0x20);
  const transcript = createGroupDeviceKeyTranscript({
    accountId: ACCOUNT,
    groupId: GROUP,
    deviceId: DEVICE,
    identityKeyVersion: 1,
    keyVersion,
    signaturePublicKey: pkSig,
    kemPublicKey: pkKem,
  });
  return {
    deviceId: DEVICE,
    pk_sig: pkSig.toString('base64'),
    pk_kem: pkKem.toString('base64'),
    key_version: keyVersion,
    identityKeyVersion: 1,
    bindingSignature: sign(
      null,
      transcript,
      state.identity.keyPair.privateKey,
    ).toString('base64'),
  };
}

async function publish(app, payload) {
  return app.inject({
    method: 'POST',
    url: `/api/keys/group/${GROUP}/devices`,
    payload,
  });
}

test('publication, rejeu idempotent et rotation conservent la version historique', async (t) => {
  const state = {
    identity: identity(),
    deviceStatus: 'active',
    current: null,
    history: [],
    directoryEvents: [],
  };
  const app = await appFor(state);
  t.after(() => app.close());

  const v1 = publication(state, 1);
  assert.equal((await publish(app, v1)).statusCode, 201);
  const replay = await publish(app, v1);
  assert.equal(replay.statusCode, 201);
  assert.equal(replay.json().rotated, false);
  assert.equal(state.directoryEvents.length, 1);

  const conflict = await publish(app, publication(state, 1, 9));
  assert.equal(conflict.statusCode, 409);
  assert.equal(conflict.json().error, 'key_version_conflict');

  const rotated = await publish(app, publication(state, 2));
  assert.equal(rotated.statusCode, 201);
  assert.equal(rotated.json().rotated, true);
  assert.equal(state.current.key_version, 2);
  assert.deepEqual(state.history.map((entry) => entry.keyVersion), [1]);
  assert.deepEqual(state.directoryEvents, [
    {
      room: `group:${GROUP}`,
      event: 'device:key-directory-changed',
      payload: {
        type: 'device:key-directory-changed',
        groupId: GROUP,
        deviceId: DEVICE,
        keyVersion: 1,
      },
    },
    {
      room: `group:${GROUP}`,
      event: 'device:key-directory-changed',
      payload: {
        type: 'device:key-directory-changed',
        groupId: GROUP,
        deviceId: DEVICE,
        keyVersion: 2,
      },
    },
  ]);

  const gap = await publish(app, publication(state, 4));
  assert.equal(gap.statusCode, 409);
  assert.equal(gap.json().error, 'key_version_gap');
});

test('une signature altérée ou un appareil révoqué ne publie aucune clé', async (t) => {
  const state = {
    identity: identity(),
    deviceStatus: 'active',
    current: null,
    history: [],
    directoryEvents: [],
  };
  const app = await appFor(state);
  t.after(() => app.close());

  const forged = publication(state, 1);
  forged.bindingSignature = Buffer.alloc(64).toString('base64');
  const invalid = await publish(app, forged);
  assert.equal(invalid.statusCode, 403);
  assert.equal(invalid.json().error, 'invalid_key_binding');
  assert.equal(state.current, null);

  state.deviceStatus = 'revoked';
  const revoked = await publish(app, publication(state, 1));
  assert.equal(revoked.statusCode, 403);
  assert.equal(revoked.json().error, 'device_not_active');
  assert.equal(state.current, null);
});
