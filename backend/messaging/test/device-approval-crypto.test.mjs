import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import test from 'node:test';

import {
  buildDeviceApprovalTranscript,
  verifyDeviceApproval,
} from '../dist/security/deviceApproval.js';

const VECTOR = {
  challengeId: '11111111-1111-4111-8111-111111111111',
  accountId: '22222222-2222-4222-8222-222222222222',
  approverDeviceId: '33333333-3333-4333-8333-333333333333',
  approverIdentityKeyVersion: 7,
  approverIdentityPublicKey: Buffer.from(
    Array.from({ length: 32 }, (_, index) => index),
  ),
  targetDeviceId: '44444444-4444-4444-8444-444444444444',
  targetIdentityKeyVersion: 9,
  targetIdentityPublicKey: Buffer.from(
    Array.from({ length: 32 }, (_, index) => 32 + index),
  ),
  decision: 'approve',
  challengeNonce: Buffer.from(
    Array.from({ length: 32 }, (_, index) => 160 + index),
  ),
  expiresAtUnixSeconds: 2_000_000_000,
};

const VECTOR_BASE64 =
  'Y2lyY2xlaGF2ZW4vYWNjb3VudC1kZXZpY2UtYXBwcm92YWwvdjEAERERERERQRGBERERERERESIiIiIiIkIigiIiIiIiIiIzMzMzMzNDM4MzMzMzMzMzAAAABwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fRERERERERESERERERERERAAAAAkgISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+PwGgoaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+vwAAAAB3NZQA';

test('la transcription d’approbation V1 correspond au vecteur figé', () => {
  const transcript = buildDeviceApprovalTranscript(VECTOR);

  assert.equal(transcript.length, 216);
  assert.equal(transcript.toString('base64'), VECTOR_BASE64);
});

test('la décision, les deux appareils et les versions sont authentifiés', () => {
  const keyPair = generateKeyPairSync('ed25519');
  const publicDer = keyPair.publicKey.export({ format: 'der', type: 'spki' });
  const approverPublicKey = Buffer.from(publicDer).subarray(-32);
  const transcript = buildDeviceApprovalTranscript({
    ...VECTOR,
    approverIdentityPublicKey: approverPublicKey,
  });
  const signature = sign(null, transcript, keyPair.privateKey);

  assert.equal(
    verifyDeviceApproval(approverPublicKey, transcript, signature),
    true,
  );

  for (const changed of [
    { targetDeviceId: '55555555-5555-4555-8555-555555555555' },
    { targetIdentityKeyVersion: 10 },
    { approverIdentityKeyVersion: 8 },
    { decision: 'reject' },
  ]) {
    const altered = buildDeviceApprovalTranscript({
      ...VECTOR,
      approverIdentityPublicKey: approverPublicKey,
      ...changed,
    });
    assert.equal(
      verifyDeviceApproval(approverPublicKey, altered, signature),
      false,
    );
  }
});

test('un appareil ne peut pas s’auto-approuver dans la transcription', () => {
  assert.throws(() =>
    buildDeviceApprovalTranscript({
      ...VECTOR,
      targetDeviceId: VECTOR.approverDeviceId,
    }),
  );
});
