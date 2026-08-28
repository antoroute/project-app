import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import {
  createDeviceAccessTranscript,
  verifyEd25519Signature,
} from '../dist/security/deviceAccess.js';
import {
  createGroupDeviceKeyTranscript,
  verifyGroupDeviceKeyBinding,
} from '../dist/security/groupDeviceKeyBinding.js';
import { authenticateDeviceAccess } from '../dist/middlewares/deviceAuth.js';

const ACCOUNT = '11111111-1111-4111-8111-111111111111';
const SECOND = '22222222-2222-4222-8222-222222222222';
const THIRD = '33333333-3333-4333-8333-333333333333';

function identity() {
  const keyPair = generateKeyPairSync('ed25519');
  const der = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  return { keyPair, publicKey: Buffer.from(der).subarray(-32) };
}

test('la preuve d’accès appareil correspond au vecteur figé de 89 octets', () => {
  const transcript = createDeviceAccessTranscript({
    accountId: ACCOUNT,
    deviceId: SECOND,
    identityKeyVersion: 7,
    accessTokenId: THIRD,
  });
  assert.equal(transcript.length, 89);
  assert.equal(
    transcript.toString('base64'),
    'Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtYWNjZXNzL3YxABEREREREUERgREREREREREiIiIiIiJCIoIiIiIiIiIiAAAABzMzMzMzM0MzgzMzMzMzMzM=',
  );
});

test('la preuve d’accès lie le jti, le compte, l’appareil et la version', () => {
  const deviceIdentity = identity();
  const transcript = createDeviceAccessTranscript({
    accountId: ACCOUNT,
    deviceId: SECOND,
    identityKeyVersion: 1,
    accessTokenId: THIRD,
  });
  const signature = sign(null, transcript, deviceIdentity.keyPair.privateKey);
  assert.equal(
    verifyEd25519Signature(
      deviceIdentity.publicKey,
      transcript,
      signature,
    ),
    true,
  );
  const otherToken = createDeviceAccessTranscript({
    accountId: ACCOUNT,
    deviceId: SECOND,
    identityKeyVersion: 1,
    accessTokenId: '44444444-4444-4444-8444-444444444444',
  });
  assert.equal(
    verifyEd25519Signature(
      deviceIdentity.publicKey,
      otherToken,
      signature,
    ),
    false,
  );
});

test('la liaison de clé de cercle correspond au vecteur figé de 152 octets', () => {
  const transcript = createGroupDeviceKeyTranscript({
    accountId: ACCOUNT,
    groupId: SECOND,
    deviceId: THIRD,
    identityKeyVersion: 7,
    keyVersion: 9,
    signaturePublicKey: Buffer.from(
      Array.from({ length: 32 }, (_, index) => index),
    ),
    kemPublicKey: Buffer.from(
      Array.from({ length: 32 }, (_, index) => 0x20 + index),
    ),
  });
  assert.equal(transcript.length, 152);
  assert.equal(
    transcript.toString('base64'),
    'Y2lyY2xlaGF2ZW4vZ3JvdXAtZGV2aWNlLWtleS92MQARERERERFBEYERERERERERIiIiIiIiQiKCIiIiIiIiIjMzMzMzM0MzgzMzMzMzMzMAAAAHAAAACQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=',
  );
});

test('une altération de clé ou de version invalide la liaison de cercle', () => {
  const deviceIdentity = identity();
  const input = {
    accountId: ACCOUNT,
    groupId: SECOND,
    deviceId: THIRD,
    identityKeyVersion: 1,
    keyVersion: 1,
    signaturePublicKey: Buffer.alloc(32, 0x11),
    kemPublicKey: Buffer.alloc(32, 0x22),
  };
  const transcript = createGroupDeviceKeyTranscript(input);
  const signature = sign(null, transcript, deviceIdentity.keyPair.privateKey);
  assert.equal(
    verifyGroupDeviceKeyBinding(
      deviceIdentity.publicKey,
      transcript,
      signature,
    ),
    true,
  );
  assert.equal(
    verifyGroupDeviceKeyBinding(
      deviceIdentity.publicKey,
      createGroupDeviceKeyTranscript({ ...input, keyVersion: 2 }),
      signature,
    ),
    false,
  );
});

test('l’autorisation serveur restitue l’état courant et refuse un appareil usurpé', async () => {
  const deviceIdentity = identity();
  const claims = {
    sub: ACCOUNT,
    jti: THIRD,
    typ: 'access',
    ver: 1,
    iss: 'trust-circle-auth',
    aud: 'trust-circle-api',
    iat: 1,
    exp: 2,
  };
  const transcript = createDeviceAccessTranscript({
    accountId: ACCOUNT,
    deviceId: SECOND,
    identityKeyVersion: 1,
    accessTokenId: THIRD,
  });
  const proof = sign(
    null,
    transcript,
    deviceIdentity.keyPair.privateKey,
  ).toString('base64');
  const db = {
    oneOrNone: async (_query, params) =>
      params[1] === SECOND
        ? {
            identity_public_key: deviceIdentity.publicKey,
            identity_key_version: 1,
            status: 'revoked',
          }
        : null,
  };
  const authenticated = await authenticateDeviceAccess(db, claims, {
    deviceId: SECOND,
    identityKeyVersion: '1',
    proof,
  });
  assert.equal(authenticated.status, 'revoked');

  assert.equal(
    await authenticateDeviceAccess(db, claims, {
      deviceId: '44444444-4444-4444-8444-444444444444',
      identityKeyVersion: '1',
      proof,
    }),
    null,
  );
});
