import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import Fastify from 'fastify';

import accountDeviceRoutes from '../dist/routes/account.devices.js';
import {
  JWT_ACCESS_AUDIENCE,
  JWT_ISSUER,
  JWT_TOKEN_VERSION,
} from '../dist/security/jwt.js';

const ACCOUNT_A = '11111111-1111-4111-8111-111111111111';
const ACCOUNT_B = '22222222-2222-4222-8222-222222222222';
const DEVICE_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const DEVICE_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

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

function createState() {
  return {
    users: new Set([ACCOUNT_A, ACCOUNT_B]),
    challenges: new Map(),
    devices: new Map(),
    grants: new Map(),
  };
}

function deviceKey(userId, deviceId) {
  return `${userId}\0${deviceId}`;
}

function normalized(query) {
  return query.replace(/\s+/g, ' ').trim();
}

function createDatabase(state) {
  let transactionTail = Promise.resolve();

  const executor = {
    oneOrNone: async (query, params) => {
      const sql = normalized(query);
      if (sql.includes('FROM users WHERE id = $1 FOR UPDATE')) {
        return state.users.has(params[0]) ? { id: params[0] } : null;
      }
      if (
        sql.includes('FROM device_registration_challenges') &&
        sql.includes('WHERE id = $1 AND user_id = $2')
      ) {
        const challenge = state.challenges.get(params[0]);
        if (!challenge || challenge.userId !== params[1]) return null;
        return {
          device_id: challenge.deviceId,
          identity_public_key: challenge.identityPublicKey,
          platform: challenge.platform,
          device_name: challenge.deviceName,
          transcript: challenge.transcript,
          bootstrap_grant_id: challenge.bootstrapGrantId,
          consumed_at: challenge.consumedAt,
          expired: challenge.expiresAt.getTime() <= Date.now(),
        };
      }
      if (sql.includes('FROM device_bootstrap_grants')) {
        for (const grant of state.grants.values()) {
          if (
            grant.userId === params[0] &&
            grant.tokenHash.equals(params[1]) &&
            grant.consumedAt === null &&
            grant.expiresAt.getTime() > Date.now()
          ) {
            return { id: grant.id };
          }
        }
        return null;
      }
      if (sql.startsWith('UPDATE device_bootstrap_grants')) {
        const grant = state.grants.get(params[0]);
        if (
          !grant ||
          grant.userId !== params[1] ||
          grant.consumedAt !== null ||
          grant.expiresAt.getTime() <= Date.now()
        ) {
          return null;
        }
        grant.consumedAt = new Date();
        return { id: grant.id };
      }
      if (
        sql.includes('FROM account_devices') &&
        sql.includes('device_id = $2')
      ) {
        const device = state.devices.get(deviceKey(params[0], params[1]));
        if (!device) return null;
        return {
          status: device.status,
          identity_public_key: device.identityPublicKey,
          activated_at: device.activatedAt,
        };
      }
      if (
        sql.includes('FROM account_devices') &&
        sql.includes('identity_public_key = $2')
      ) {
        for (const device of state.devices.values()) {
          if (
            device.userId === params[0] &&
            device.identityPublicKey.equals(params[1])
          ) {
            return { device_id: device.deviceId };
          }
        }
        return null;
      }
      throw new Error(`unexpected oneOrNone query: ${sql}`);
    },
    one: async (query, params) => {
      const sql = normalized(query);
      if (sql.includes('AS account_count')) {
        const recent = [...state.challenges.values()].filter(
          (challenge) =>
            challenge.userId === params[0] &&
            challenge.createdAt.getTime() > Date.now() - 10 * 60 * 1000,
        );
        return {
          account_count: recent.length,
          device_count: recent.filter(
            (challenge) => challenge.deviceId === params[1],
          ).length,
        };
      }
      if (sql.includes('COUNT(*)::int AS count')) {
        const count = [...state.challenges.values()].filter(
          (challenge) =>
            challenge.userId === params[0] &&
            challenge.deviceId !== params[1] &&
            challenge.consumedAt === null &&
            challenge.expiresAt.getTime() > Date.now(),
        ).length;
        return { count };
      }
      if (sql.includes('AS has_ever_activated')) {
        const hasEverActivated = [...state.devices.values()].some(
          (device) =>
            device.userId === params[0] && device.activatedAt !== null,
        );
        return { has_ever_activated: hasEverActivated };
      }
      throw new Error(`unexpected one query: ${sql}`);
    },
    none: async (query, params) => {
      const sql = normalized(query);
      if (sql.startsWith('DELETE FROM device_registration_challenges')) {
        for (const [id, challenge] of state.challenges.entries()) {
          const retentionDate = challenge.consumedAt ?? challenge.expiresAt;
          if (
            challenge.userId === params[0] &&
            retentionDate.getTime() < Date.now() - 7 * 24 * 60 * 60 * 1000
          ) {
            state.challenges.delete(id);
          }
        }
        return;
      }
      if (
        sql.startsWith('UPDATE device_registration_challenges') &&
        sql.includes("result = 'superseded'")
      ) {
        for (const challenge of state.challenges.values()) {
          if (
            challenge.userId === params[0] &&
            challenge.deviceId === params[1] &&
            challenge.consumedAt === null
          ) {
            challenge.consumedAt = new Date();
            challenge.result = 'superseded';
          }
        }
        return;
      }
      if (sql.startsWith('INSERT INTO device_registration_challenges')) {
        state.challenges.set(params[0], {
          id: params[0],
          userId: params[1],
          deviceId: params[2],
          identityPublicKey: Buffer.from(params[3]),
          platform: params[4],
          deviceName: params[5],
          challengeNonce: Buffer.from(params[6]),
          transcript: Buffer.from(params[7]),
          bootstrapGrantId: params[8],
          expiresAt: new Date(Number(params[9]) * 1000),
          consumedAt: null,
          result: null,
          createdAt: new Date(),
        });
        return;
      }
      if (
        sql.startsWith('UPDATE device_registration_challenges') &&
        sql.includes('WHERE id = $1')
      ) {
        const challenge = state.challenges.get(params[0]);
        if (!challenge) throw new Error('challenge missing');
        challenge.consumedAt = new Date();
        if (sql.includes("result = 'expired'")) challenge.result = 'expired';
        else if (sql.includes("result = 'invalid_signature'")) {
          challenge.result = 'invalid_signature';
        } else if (sql.includes("result = 'device_identity_conflict'")) {
          challenge.result = 'device_identity_conflict';
        } else if (sql.includes("result = 'identity_key_conflict'")) {
          challenge.result = 'identity_key_conflict';
        } else if (sql.includes("result = 'device_revoked'")) {
          challenge.result = 'device_revoked';
        } else {
          challenge.result = params[1];
        }
        return;
      }
      if (sql.startsWith('INSERT INTO account_devices')) {
        const now = new Date();
        state.devices.set(deviceKey(params[0], params[1]), {
          userId: params[0],
          deviceId: params[1],
          identityPublicKey: Buffer.from(params[2]),
          identityKeyVersion: 1,
          platform: params[3],
          deviceName: params[4],
          status: params[5],
          proofVerifiedAt: now,
          activatedAt: params[5] === 'active' ? now : null,
          createdAt: now,
          updatedAt: now,
        });
        return;
      }
      if (sql.startsWith('UPDATE account_devices')) {
        const device = state.devices.get(deviceKey(params[0], params[1]));
        if (!device) throw new Error('device missing');
        device.platform = params[2];
        device.deviceName = params[3];
        device.proofVerifiedAt = new Date();
        if (params[4]) {
          device.status = 'active';
          device.activatedAt ??= new Date();
        }
        device.updatedAt = new Date();
        return;
      }
      throw new Error(`unexpected none query: ${sql}`);
    },
  };

  return {
    ...executor,
    any: async (query, params) => {
      const sql = normalized(query);
      if (!sql.includes('FROM account_devices')) {
        throw new Error(`unexpected any query: ${sql}`);
      }
      return [...state.devices.values()]
        .filter((device) => device.userId === params[0])
        .map((device) => ({
          device_id: device.deviceId,
          identity_public_key: device.identityPublicKey,
          identity_key_version: device.identityKeyVersion,
          platform: device.platform,
          device_name: device.deviceName,
          status: device.status,
          proof_verified_at: device.proofVerifiedAt,
          activated_at: device.activatedAt,
          created_at: device.createdAt,
          updated_at: device.updatedAt,
        }));
    },
    transaction: async (work) => {
      const run = transactionTail.then(() => work(executor));
      transactionTail = run.catch(() => undefined);
      return run;
    },
  };
}

async function deviceApp(state, accountId = ACCOUNT_A) {
  const app = Fastify({ logger: false });
  app.decorate('authenticate', async (request) => {
    request.user = claims(accountId);
  });
  app.decorate('db', createDatabase(state));
  await app.register(accountDeviceRoutes);
  await app.ready();
  return app;
}

async function requestChallenge(
  app,
  deviceId,
  publicKey,
  deviceName = 'Windows',
  bootstrapGrant,
) {
  return app.inject({
    method: 'POST',
    url: '/api/devices/registrations/challenge',
    payload: {
      deviceId,
      identityPublicKey: publicKey.toString('base64'),
      platform: 'windows',
      deviceName,
      ...(bootstrapGrant ? { bootstrapGrant } : {}),
    },
  });
}

function authorizeBootstrap(state, accountId = ACCOUNT_A, marker = 1) {
  const grant = Buffer.alloc(32, marker).toString('base64url');
  const id = `9999999${marker}-9999-4999-8999-99999999999${marker}`;
  state.grants.set(id, {
    id,
    userId: accountId,
    tokenHash: createHash('sha256').update(grant, 'ascii').digest(),
    expiresAt: new Date(Date.now() + 5 * 60 * 1000),
    consumedAt: null,
  });
  return grant;
}

function signedProof(keyPair, challengeResponse) {
  const transcript = Buffer.from(challengeResponse.transcript, 'base64');
  return sign(null, transcript, keyPair.privateKey).toString('base64');
}

async function prove(app, challengeId, signature) {
  return app.inject({
    method: 'POST',
    url: `/api/devices/registrations/${challengeId}/proof`,
    payload: { signature },
  });
}

test('le premier appareil prouvé bootstrap une seule fois et le rejeu échoue', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const firstIdentity = identity();
  const bootstrapGrant = authorizeBootstrap(state);

  const challengeResponse = await requestChallenge(
    app,
    DEVICE_A,
    firstIdentity.publicKey,
    'Windows',
    bootstrapGrant,
  );
  assert.equal(challengeResponse.statusCode, 201);
  const challenge = challengeResponse.json();

  const proofResponse = await prove(
    app,
    challenge.challengeId,
    signedProof(firstIdentity.keyPair, challenge),
  );
  assert.equal(proofResponse.statusCode, 201);
  assert.deepEqual(proofResponse.json(), {
    deviceId: DEVICE_A,
    status: 'active',
    bootstrap: true,
  });

  const replay = await prove(
    app,
    challenge.challengeId,
    signedProof(firstIdentity.keyPair, challenge),
  );
  assert.equal(replay.statusCode, 409);
  assert.equal(replay.json().error, 'device_challenge_consumed');
});

test('une session sans clé privée échoue et consomme le challenge', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const deviceIdentity = identity();
  const challengeResponse = await requestChallenge(
    app,
    DEVICE_A,
    deviceIdentity.publicKey,
  );
  const challenge = challengeResponse.json();

  const invalid = await prove(
    app,
    challenge.challengeId,
    Buffer.alloc(64).toString('base64'),
  );
  assert.equal(invalid.statusCode, 403);
  assert.equal(invalid.json().error, 'invalid_device_proof');
  assert.equal(state.devices.size, 0);

  const retry = await prove(
    app,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );
  assert.equal(retry.statusCode, 409);
});

test('une clé choisie avec le seul access token ne peut pas bootstrap', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const attackerIdentity = identity();
  const challenge = (
    await requestChallenge(app, DEVICE_A, attackerIdentity.publicKey)
  ).json();

  const proof = await prove(
    app,
    challenge.challengeId,
    signedProof(attackerIdentity.keyPair, challenge),
  );
  assert.equal(proof.statusCode, 403);
  assert.equal(proof.json().error, 'bootstrap_authorization_required');
  assert.equal(state.devices.size, 0);
});

test('deux preuves bootstrap concurrentes produisent actif puis pending', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const firstIdentity = identity();
  const secondIdentity = identity();
  const bootstrapGrant = authorizeBootstrap(state);
  const firstChallenge = (
    await requestChallenge(
      app,
      DEVICE_A,
      firstIdentity.publicKey,
      'Android',
      bootstrapGrant,
    )
  ).json();
  const secondChallenge = (
    await requestChallenge(
      app,
      DEVICE_B,
      secondIdentity.publicKey,
      'Windows',
      bootstrapGrant,
    )
  ).json();

  const responses = await Promise.all([
    prove(
      app,
      firstChallenge.challengeId,
      signedProof(firstIdentity.keyPair, firstChallenge),
    ),
    prove(
      app,
      secondChallenge.challengeId,
      signedProof(secondIdentity.keyPair, secondChallenge),
    ),
  ]);

  assert.deepEqual(
    responses.map((response) => response.json().status).sort(),
    ['active', 'pending'],
  );
  assert.equal(
    responses.filter((response) => response.json().bootstrap).length,
    1,
  );
});

test('un challenge expiré est refusé et consommé', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const deviceIdentity = identity();
  const challenge = (
    await requestChallenge(app, DEVICE_A, deviceIdentity.publicKey)
  ).json();
  state.challenges.get(challenge.challengeId).expiresAt = new Date(0);

  const expired = await prove(
    app,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );
  assert.equal(expired.statusCode, 410);
  assert.equal(expired.json().error, 'device_challenge_expired');

  const replay = await prove(
    app,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );
  assert.equal(replay.statusCode, 409);
});

test('un nouveau challenge du même appareil invalide le précédent', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const deviceIdentity = identity();
  const bootstrapGrant = authorizeBootstrap(state);
  const first = (
    await requestChallenge(
      app,
      DEVICE_A,
      deviceIdentity.publicKey,
      'Windows',
      bootstrapGrant,
    )
  ).json();
  const second = (
    await requestChallenge(
      app,
      DEVICE_A,
      deviceIdentity.publicKey,
      'Windows',
      bootstrapGrant,
    )
  ).json();

  const superseded = await prove(
    app,
    first.challengeId,
    signedProof(deviceIdentity.keyPair, first),
  );
  assert.equal(superseded.statusCode, 409);

  const current = await prove(
    app,
    second.challengeId,
    signedProof(deviceIdentity.keyPair, second),
  );
  assert.equal(current.statusCode, 201);
});

test('les limites bornent les challenges simultanés et répétés', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());

  for (let index = 1; index <= 8; index += 1) {
    const deviceId = `0000000${index}-0000-4000-8000-00000000000${index}`;
    const response = await requestChallenge(
      app,
      deviceId,
      identity().publicKey,
    );
    assert.equal(response.statusCode, 201);
  }
  const ninth = await requestChallenge(
    app,
    '00000009-0000-4000-8000-000000000009',
    identity().publicKey,
  );
  assert.equal(ninth.statusCode, 429);
  assert.equal(ninth.json().error, 'too_many_device_challenges');

  const secondState = createState();
  const secondApp = await deviceApp(secondState);
  t.after(() => secondApp.close());
  const repeatedIdentity = identity();
  for (let index = 0; index < 6; index += 1) {
    const response = await requestChallenge(
      secondApp,
      DEVICE_A,
      repeatedIdentity.publicKey,
    );
    assert.equal(response.statusCode, 201);
  }
  const seventh = await requestChallenge(
    secondApp,
    DEVICE_A,
    repeatedIdentity.publicKey,
  );
  assert.equal(seventh.statusCode, 429);
});

test('un autre compte ne peut ni voir ni consommer le challenge', async (t) => {
  const state = createState();
  const appA = await deviceApp(state, ACCOUNT_A);
  const appB = await deviceApp(state, ACCOUNT_B);
  t.after(async () => {
    await appA.close();
    await appB.close();
  });
  const deviceIdentity = identity();
  const bootstrapGrant = authorizeBootstrap(state, ACCOUNT_A);
  const challenge = (
    await requestChallenge(
      appA,
      DEVICE_A,
      deviceIdentity.publicKey,
      'Windows',
      bootstrapGrant,
    )
  ).json();

  const hidden = await prove(
    appB,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );
  assert.equal(hidden.statusCode, 404);
  assert.equal(hidden.json().error, 'device_challenge_not_found');

  const owner = await prove(
    appA,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );
  assert.equal(owner.statusCode, 201);
});

test('la liste ne retourne que les appareils du sujet authentifié', async (t) => {
  const state = createState();
  const app = await deviceApp(state);
  t.after(() => app.close());
  const deviceIdentity = identity();
  const bootstrapGrant = authorizeBootstrap(state);
  const challenge = (
    await requestChallenge(
      app,
      DEVICE_A,
      deviceIdentity.publicKey,
      'Windows',
      bootstrapGrant,
    )
  ).json();
  await prove(
    app,
    challenge.challengeId,
    signedProof(deviceIdentity.keyPair, challenge),
  );

  const response = await app.inject({ method: 'GET', url: '/api/devices' });
  assert.equal(response.statusCode, 200);
  assert.equal(response.json().length, 1);
  assert.equal(response.json()[0].deviceId, DEVICE_A);
  assert.equal(response.json()[0].status, 'active');
});
