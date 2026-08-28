import { createPublicKey, verify } from 'node:crypto';

import type { AccessTokenClaims } from './jwt.js';

export const DEVICE_ACCESS_DOMAIN = Buffer.from(
  'circlehaven/account-device-access/v1\0',
  'ascii',
);
export const DEVICE_ACCESS_TRANSCRIPT_LENGTH = 89;

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function uuidBytes(value: string): Buffer {
  if (!UUID_PATTERN.test(value)) throw new Error('invalid_uuid');
  return Buffer.from(value.replaceAll('-', ''), 'hex');
}

function versionBytes(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 1 || value > 0xffffffff) {
    throw new Error('invalid_identity_key_version');
  }
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return bytes;
}

export function createDeviceAccessTranscript(input: {
  accountId: string;
  deviceId: string;
  identityKeyVersion: number;
  accessTokenId: string;
}): Buffer {
  const transcript = Buffer.concat([
    DEVICE_ACCESS_DOMAIN,
    uuidBytes(input.accountId),
    uuidBytes(input.deviceId),
    versionBytes(input.identityKeyVersion),
    uuidBytes(input.accessTokenId),
  ]);
  if (transcript.length !== DEVICE_ACCESS_TRANSCRIPT_LENGTH) {
    throw new Error('invalid_device_access_transcript_length');
  }
  return transcript;
}

export function verifyEd25519Signature(
  publicKey: Buffer,
  transcript: Buffer,
  signature: Buffer,
): boolean {
  if (publicKey.length !== 32 || signature.length !== 64) return false;
  try {
    return verify(
      null,
      transcript,
      createPublicKey({
        key: Buffer.concat([ED25519_SPKI_PREFIX, publicKey]),
        format: 'der',
        type: 'spki',
      }),
      signature,
    );
  } catch {
    return false;
  }
}

export function deviceAccessTranscriptForClaims(
  claims: AccessTokenClaims,
  deviceId: string,
  identityKeyVersion: number,
): Buffer {
  return createDeviceAccessTranscript({
    accountId: claims.sub,
    deviceId,
    identityKeyVersion,
    accessTokenId: claims.jti,
  });
}
