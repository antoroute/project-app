import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import {
  buildDeviceProofTranscript,
  decodeCanonicalBase64,
  hashBootstrapGrant,
  verifyDeviceProof,
} from '../dist/security/deviceProof.js';

const VECTOR = {
  challengeId: '11111111-1111-4111-8111-111111111111',
  accountId: '22222222-2222-4222-8222-222222222222',
  deviceId: '33333333-3333-4333-8333-333333333333',
  identityPublicKey: Buffer.from(
    Array.from({ length: 32 }, (_, index) => index),
  ),
  challengeNonce: Buffer.from(
    Array.from({ length: 32 }, (_, index) => 160 + index),
  ),
  expiresAtUnixSeconds: 2_000_000_000,
};

const VECTOR_BASE64 =
  'Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtcmVnaXN0cmF0aW9uL3YxABEREREREUERgREREREREREiIiIiIiJCIoIiIiIiIiIiMzMzMzMzQzODMzMzMzMzMwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4foKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8AAAAAdzWUAA==';

test('la transcription binaire V1 correspond au vecteur figé', () => {
  const transcript = buildDeviceProofTranscript(VECTOR);

  assert.equal(transcript.length, 163);
  assert.equal(transcript.toString('base64'), VECTOR_BASE64);
});

test('une preuve Ed25519 valide passe et toute altération échoue', () => {
  const keyPair = generateKeyPairSync('ed25519');
  const publicDer = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  const rawPublicKey = Buffer.from(publicDer).subarray(-32);
  const transcript = buildDeviceProofTranscript({
    ...VECTOR,
    identityPublicKey: rawPublicKey,
  });
  const signature = sign(null, transcript, keyPair.privateKey);

  assert.equal(
    verifyDeviceProof(rawPublicKey, transcript, signature),
    true,
  );

  const altered = Buffer.from(transcript);
  altered[altered.length - 1] ^= 1;
  assert.equal(verifyDeviceProof(rawPublicKey, altered, signature), false);
  assert.equal(
    verifyDeviceProof(rawPublicKey, transcript, Buffer.alloc(64)),
    false,
  );
});

test('seul le Base64 canonique de la taille attendue est accepté', () => {
  const canonical = Buffer.alloc(32, 7).toString('base64');
  assert.deepEqual(decodeCanonicalBase64(canonical, 32), Buffer.alloc(32, 7));

  assert.throws(() => decodeCanonicalBase64(`${canonical}\n`, 32));
  assert.throws(() => decodeCanonicalBase64(canonical.slice(0, -1), 32));
  assert.throws(() => decodeCanonicalBase64(Buffer.alloc(31).toString('base64'), 32));
});

test('le grant de bootstrap est canonique puis haché avant stockage', () => {
  const grant = Buffer.alloc(32, 9).toString('base64url');
  const digest = hashBootstrapGrant(grant);

  assert.equal(digest.length, 32);
  assert.throws(() => hashBootstrapGrant(`${grant}=`));
  assert.throws(() => hashBootstrapGrant(grant.slice(0, -1)));
});
