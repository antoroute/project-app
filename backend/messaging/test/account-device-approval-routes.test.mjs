import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import Fastify from 'fastify';

import accountDeviceApprovalRoutes from '../dist/routes/account.deviceApprovals.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const ACCOUNT_A = '11111111-1111-4111-8111-111111111111';
const ACCOUNT_B = '22222222-2222-4222-8222-222222222222';
const DEVICE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const DEVICE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const DEVICE_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

function claims(accountId) {
  const now = Math.floor(Date.now() / 1000);
  return {
    sub: accountId,
    iss: JWT_ISSUER,
    aud: JWT_ACCESS_AUDIENCE,
    iat: now,
    exp: now + 900,
    jti: '66666666-6666-4666-8666-666666666666',
    typ: 'access',
    ver: JWT_TOKEN_VERSION,
  };
}

function identity() {
  const keyPair = generateKeyPairSync('ed25519');
  const publicDer = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  return {
    keyPair,
    publicKey: Buffer.from(publicDer).subarray(-32),
  };
}

function deviceKey(userId, deviceId) {
  return `${userId}\0${deviceId}`;
}

function createState() {
  return {
    users: new Set([ACCOUNT_A, ACCOUNT_B]),
    devices: new Map(),
    approvals: new Map(),
  };
}

function addDevice(state, userId, deviceId, deviceIdentity, status) {
  const now = new Date();
  state.devices.set(deviceKey(userId, deviceId), {
    userId,
    deviceId,
    identityPublicKey: Buffer.from(deviceIdentity.publicKey),
    identityKeyVersion: 1,
    platform: 'windows',
    deviceName: `${status} ${deviceId.slice(0, 4)}`,
    status,
    activatedAt: status === 'active' ? now : null,
    revokedAt: status === 'revoked' ? now : null,
    updatedAt: now,
  });
}

function normalized(query) {
  return query.replace(/\s+/g, ' ').trim();
}

function database(state) {
  let transactionTail = Promise.resolve();
  const executor = {
    oneOrNone: async (query, params) => {
      const sql = normalized(query);
      if (sql.includes('FROM users WHERE id = $1 FOR UPDATE')) {
        return state.users.has(params[0]) ? { id: params[0] } : null;
      }
      if (sql.includes('FROM device_approval_challenges')) {
        const approval = state.approvals.get(params[0]);
        if (!approval || approval.userId !== params[1]) return null;
        return {
          approver_device_id: approval.approverDeviceId,
          approver_identity_key_version:
            approval.approverIdentityKeyVersion,
          approver_identity_public_key: approval.approverIdentityPublicKey,
          target_device_id: approval.targetDeviceId,
          target_identity_key_version: approval.targetIdentityKeyVersion,
          target_identity_public_key: approval.targetIdentityPublicKey,
          decision: approval.decision,
          transcript: approval.transcript,
          consumed_at: approval.consumedAt,
          expired: approval.expiresAt.getTime() <= Date.now(),
        };
      }
      if (sql.includes('FROM account_devices')) {
        const device = state.devices.get(deviceKey(params[0], params[1]));
        if (!device) return null;
        return {
          device_id: device.deviceId,
          identity_public_key: device.identityPublicKey,
          identity_key_version: device.identityKeyVersion,
          platform: device.platform,
          device_name: device.deviceName,
          status: device.status,
        };
      }
      throw new Error(`unexpected oneOrNone query: ${sql}`);
    },
    one: async (query, params) => {
      const sql = normalized(query);
      if (sql.includes('AS account_count')) {
        const recent = [...state.approvals.values()].filter(
          (approval) =>
            approval.userId === params[0] &&
            approval.createdAt.getTime() > Date.now() - 10 * 60 * 1000,
        );
        return {
          account_count: recent.length,
          target_count: recent.filter(
            (approval) => approval.targetDeviceId === params[1],
          ).length,
        };
      }
      if (sql.includes('COUNT(*)::int AS count')) {
        return {
          count: [...state.approvals.values()].filter(
            (approval) =>
              approval.userId === params[0] &&
              !(
                approval.approverDeviceId === params[1] &&
                approval.targetDeviceId === params[2]
              ) &&
              approval.consumedAt === null &&
              approval.expiresAt.getTime() > Date.now(),
          ).length,
        };
      }
      throw new Error(`unexpected one query: ${sql}`);
    },
    none: async (query, params) => {
      const sql = normalized(query);
      if (sql.startsWith('DELETE FROM device_approval_challenges')) {
        for (const [id, approval] of state.approvals.entries()) {
          const retentionDate = approval.consumedAt ?? approval.expiresAt;
          if (
            approval.userId === params[0] &&
            retentionDate.getTime() < Date.now() - 7 * 24 * 60 * 60 * 1000
          ) {
            state.approvals.delete(id);
          }
        }
        return;
      }
      if (sql.startsWith('INSERT INTO device_approval_challenges')) {
        state.approvals.set(params[0], {
          id: params[0],
          userId: params[1],
          approverDeviceId: params[2],
          approverIdentityKeyVersion: params[3],
          approverIdentityPublicKey: Buffer.from(params[4]),
          targetDeviceId: params[5],
          targetIdentityKeyVersion: params[6],
          targetIdentityPublicKey: Buffer.from(params[7]),
          decision: params[8],
          challengeNonce: Buffer.from(params[9]),
          transcript: Buffer.from(params[10]),
          expiresAt: new Date(Number(params[11]) * 1000),
          consumedAt: null,
          result: null,
          createdAt: new Date(),
        });
        return;
      }
      if (sql.startsWith('UPDATE account_devices')) {
        const device = state.devices.get(deviceKey(params[0], params[1]));
        if (!device) throw new Error('device missing');
        if (sql.includes("status = 'active'")) {
          device.status = 'active';
          device.activatedAt = new Date();
          device.revokedAt = null;
        } else if (sql.includes("status = 'revoked'")) {
          device.status = 'revoked';
          device.revokedAt = new Date();
        }
        device.updatedAt = new Date();
        return;
      }
      if (
        sql.startsWith('UPDATE device_approval_challenges') &&
        sql.includes("result = 'superseded_by_decision'")
      ) {
        for (const approval of state.approvals.values()) {
          if (
            approval.userId === params[0] &&
            approval.targetDeviceId === params[1] &&
            approval.id !== params[2] &&
            approval.consumedAt === null
          ) {
            approval.consumedAt = new Date();
            approval.result = 'superseded_by_decision';
          }
        }
        return;
      }
      if (
        sql.startsWith('UPDATE device_approval_challenges') &&
        sql.includes("result = 'superseded'")
      ) {
        for (const approval of state.approvals.values()) {
          if (
            approval.userId === params[0] &&
            approval.approverDeviceId === params[1] &&
            approval.targetDeviceId === params[2] &&
            approval.consumedAt === null
          ) {
            approval.consumedAt = new Date();
            approval.result = 'superseded';
          }
        }
        return;
      }
      if (sql.startsWith('UPDATE device_approval_challenges')) {
        const approval = state.approvals.get(params[0]);
        if (!approval) throw new Error('approval missing');
        approval.consumedAt = new Date();
        approval.result = params[1];
        return;
      }
      throw new Error(`unexpected none query: ${sql}`);
    },
  };
  return {
    ...executor,
    any: async () => [],
    transaction: async (work) => {
      const run = transactionTail.then(() => work(executor));
      transactionTail = run.catch(() => undefined);
      return run;
    },
  };
}

async function appFor(state, accountId = ACCOUNT_A) {
  const app = Fastify({ logger: false });
  app.decorate('authenticate', async (request) => {
    request.user = claims(accountId);
  });
  app.decorate('db', database(state));
  await app.register(accountDeviceApprovalRoutes);
  await app.ready();
  return app;
}

async function requestApproval(
  app,
  targetDeviceId,
  approverDeviceId,
  decision = 'approve',
) {
  return app.inject({
    method: 'POST',
    url: `/api/devices/${targetDeviceId}/approvals/challenge`,
    payload: { approverDeviceId, decision },
  });
}

async function decide(app, challenge, keyPair) {
  const signature = sign(
    null,
    Buffer.from(challenge.transcript, 'base64'),
    keyPair.privateKey,
  ).toString('base64');
  return app.inject({
    method: 'POST',
    url: `/api/devices/approvals/${challenge.challengeId}/decision`,
    payload: { signature },
  });
}

function activeAndPending(state) {
  const active = identity();
  const pending = identity();
  addDevice(state, ACCOUNT_A, DEVICE_A, active, 'active');
  addDevice(state, ACCOUNT_A, DEVICE_B, pending, 'pending');
  return { active, pending };
}

test('un appareil actif approuve la cible pending et le rejeu échoue', async (t) => {
  const state = createState();
  const { active } = activeAndPending(state);
  const app = await appFor(state);
  t.after(() => app.close());

  const challengeResponse = await requestApproval(app, DEVICE_B, DEVICE_A);
  assert.equal(challengeResponse.statusCode, 201);
  const challenge = challengeResponse.json();
  assert.equal(Buffer.from(challenge.transcript, 'base64').length, 216);
  assert.equal(challenge.target.deviceId, DEVICE_B);

  const approved = await decide(app, challenge, active.keyPair);
  assert.equal(approved.statusCode, 200);
  assert.deepEqual(approved.json(), {
    targetDeviceId: DEVICE_B,
    approverDeviceId: DEVICE_A,
    decision: 'approve',
    status: 'active',
  });
  assert.equal(state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status, 'active');

  const replay = await decide(app, challenge, active.keyPair);
  assert.equal(replay.statusCode, 409);
  assert.equal(replay.json().error, 'device_approval_challenge_consumed');
});

test('une signature invalide consomme la décision sans activer la cible', async (t) => {
  const state = createState();
  activeAndPending(state);
  const app = await appFor(state);
  t.after(() => app.close());
  const challenge = (
    await requestApproval(app, DEVICE_B, DEVICE_A)
  ).json();

  const invalid = await app.inject({
    method: 'POST',
    url: `/api/devices/approvals/${challenge.challengeId}/decision`,
    payload: { signature: Buffer.alloc(64).toString('base64') },
  });
  assert.equal(invalid.statusCode, 403);
  assert.equal(invalid.json().error, 'invalid_device_approval');
  assert.equal(state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status, 'pending');

  const replay = await app.inject({
    method: 'POST',
    url: `/api/devices/approvals/${challenge.challengeId}/decision`,
    payload: { signature: Buffer.alloc(64).toString('base64') },
  });
  assert.equal(replay.statusCode, 409);
});

test('un appareil pending ne peut pas devenir approbateur avec son access token', async (t) => {
  const state = createState();
  const pendingA = identity();
  const pendingB = identity();
  addDevice(state, ACCOUNT_A, DEVICE_A, pendingA, 'pending');
  addDevice(state, ACCOUNT_A, DEVICE_B, pendingB, 'pending');
  const app = await appFor(state);
  t.after(() => app.close());

  const response = await requestApproval(app, DEVICE_B, DEVICE_A);
  assert.equal(response.statusCode, 403);
  assert.equal(response.json().error, 'approver_device_not_active');
  assert.equal(state.approvals.size, 0);
});

test('un approbateur révoqué après émission ne peut plus décider', async (t) => {
  const state = createState();
  const { active } = activeAndPending(state);
  const app = await appFor(state);
  t.after(() => app.close());
  const challenge = (
    await requestApproval(app, DEVICE_B, DEVICE_A)
  ).json();
  state.devices.get(deviceKey(ACCOUNT_A, DEVICE_A)).status = 'revoked';

  const response = await decide(app, challenge, active.keyPair);
  assert.equal(response.statusCode, 403);
  assert.equal(response.json().error, 'approver_device_not_active');
  assert.equal(state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status, 'pending');
});

test('deux décisions concurrentes ont un seul gagnant', async (t) => {
  const state = createState();
  const firstActive = identity();
  const secondActive = identity();
  const pending = identity();
  addDevice(state, ACCOUNT_A, DEVICE_A, firstActive, 'active');
  addDevice(state, ACCOUNT_A, DEVICE_C, secondActive, 'active');
  addDevice(state, ACCOUNT_A, DEVICE_B, pending, 'pending');
  const app = await appFor(state);
  t.after(() => app.close());

  const approveChallenge = (
    await requestApproval(app, DEVICE_B, DEVICE_A, 'approve')
  ).json();
  const rejectChallenge = (
    await requestApproval(app, DEVICE_B, DEVICE_C, 'reject')
  ).json();
  const responses = await Promise.all([
    decide(app, approveChallenge, firstActive.keyPair),
    decide(app, rejectChallenge, secondActive.keyPair),
  ]);

  assert.deepEqual(
    responses.map((response) => response.statusCode).sort(),
    [200, 409],
  );
  assert.ok(
    ['active', 'revoked'].includes(
      state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status,
    ),
  );
});

test('un refus signé révoque la cible pending et empêche une nouvelle décision', async (t) => {
  const state = createState();
  const { active } = activeAndPending(state);
  const app = await appFor(state);
  t.after(() => app.close());
  const challenge = (
    await requestApproval(app, DEVICE_B, DEVICE_A, 'reject')
  ).json();

  const rejected = await decide(app, challenge, active.keyPair);
  assert.equal(rejected.statusCode, 200);
  assert.equal(rejected.json().status, 'revoked');
  assert.equal(state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status, 'revoked');

  const another = await requestApproval(app, DEVICE_B, DEVICE_A);
  assert.equal(another.statusCode, 409);
  assert.equal(another.json().error, 'target_device_not_pending');
});

test('un autre compte ne découvre ni ne consomme la décision', async (t) => {
  const state = createState();
  const { active } = activeAndPending(state);
  const appA = await appFor(state, ACCOUNT_A);
  const appB = await appFor(state, ACCOUNT_B);
  t.after(async () => {
    await appA.close();
    await appB.close();
  });
  const challenge = (
    await requestApproval(appA, DEVICE_B, DEVICE_A)
  ).json();

  const hidden = await decide(appB, challenge, active.keyPair);
  assert.equal(hidden.statusCode, 404);
  assert.equal(hidden.json().error, 'device_approval_challenge_not_found');

  const owner = await decide(appA, challenge, active.keyPair);
  assert.equal(owner.statusCode, 200);
});

test('une décision expirée est consommée sans modifier la cible', async (t) => {
  const state = createState();
  const { active } = activeAndPending(state);
  const app = await appFor(state);
  t.after(() => app.close());
  const challenge = (
    await requestApproval(app, DEVICE_B, DEVICE_A)
  ).json();
  state.approvals.get(challenge.challengeId).expiresAt = new Date(0);

  const expired = await decide(app, challenge, active.keyPair);
  assert.equal(expired.statusCode, 410);
  assert.equal(expired.json().error, 'device_approval_challenge_expired');
  assert.equal(state.devices.get(deviceKey(ACCOUNT_A, DEVICE_B)).status, 'pending');
});
