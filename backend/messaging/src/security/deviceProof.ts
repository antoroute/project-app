import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  verify,
} from 'node:crypto';

export const DEVICE_PROOF_DOMAIN = Buffer.from(
  'circlehaven/account-device-registration/v1\0',
  'ascii',
);
export const DEVICE_PROOF_TTL_SECONDS = 5 * 60;
export const DEVICE_PROOF_MAX_OUTSTANDING = 8;
export const DEVICE_PROOF_RATE_WINDOW_MINUTES = 10;
export const DEVICE_PROOF_MAX_PER_ACCOUNT_WINDOW = 20;
export const DEVICE_PROOF_MAX_PER_DEVICE_WINDOW = 6;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

export interface DeviceProofTranscriptInput {
  challengeId: string;
  accountId: string;
  deviceId: string;
  identityPublicKey: Buffer;
  challengeNonce: Buffer;
  expiresAtUnixSeconds: number;
}

export interface DeviceChallengeMaterial extends DeviceProofTranscriptInput {
  transcript: Buffer;
}

function uuidBytes(value: string): Buffer {
  if (!UUID_PATTERN.test(value)) {
    throw new Error('invalid_uuid');
  }
  return Buffer.from(value.replaceAll('-', ''), 'hex');
}

export function decodeCanonicalBase64(
  value: string,
  expectedLength: number,
): Buffer {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error('invalid_base64');
  }
  const decoded = Buffer.from(value, 'base64');
  if (
    decoded.length !== expectedLength ||
    decoded.toString('base64') !== value
  ) {
    throw new Error('invalid_base64');
  }
  return decoded;
}

export function hashBootstrapGrant(value: string): Buffer {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new Error('invalid_bootstrap_grant');
  }
  const decoded = Buffer.from(value, 'base64url');
  if (decoded.length !== 32 || decoded.toString('base64url') !== value) {
    throw new Error('invalid_bootstrap_grant');
  }
  return createHash('sha256').update(value, 'ascii').digest();
}

export function buildDeviceProofTranscript(
  input: DeviceProofTranscriptInput,
): Buffer {
  if (input.identityPublicKey.length !== 32) {
    throw new Error('invalid_identity_public_key');
  }
  if (input.challengeNonce.length !== 32) {
    throw new Error('invalid_challenge_nonce');
  }
  if (
    !Number.isSafeInteger(input.expiresAtUnixSeconds) ||
    input.expiresAtUnixSeconds <= 0
  ) {
    throw new Error('invalid_expiration');
  }

  const expiration = Buffer.alloc(8);
  expiration.writeBigUInt64BE(BigInt(input.expiresAtUnixSeconds));

  return Buffer.concat([
    DEVICE_PROOF_DOMAIN,
    uuidBytes(input.challengeId),
    uuidBytes(input.accountId),
    uuidBytes(input.deviceId),
    input.identityPublicKey,
    input.challengeNonce,
    expiration,
  ]);
}

export function createDeviceChallengeMaterial(
  accountId: string,
  deviceId: string,
  identityPublicKey: Buffer,
  nowUnixSeconds = Math.floor(Date.now() / 1000),
): DeviceChallengeMaterial {
  const challengeId = randomUUID();
  const challengeNonce = randomBytes(32);
  const expiresAtUnixSeconds = nowUnixSeconds + DEVICE_PROOF_TTL_SECONDS;
  const input = {
    challengeId,
    accountId,
    deviceId,
    identityPublicKey,
    challengeNonce,
    expiresAtUnixSeconds,
  };
  return { ...input, transcript: buildDeviceProofTranscript(input) };
}

export function verifyEd25519Signature(
  identityPublicKey: Buffer,
  transcript: Buffer,
  signature: Buffer,
): boolean {
  if (identityPublicKey.length !== 32 || signature.length !== 64) {
    return false;
  }
  try {
    const publicKey = createPublicKey({
      key: Buffer.concat([ED25519_SPKI_PREFIX, identityPublicKey]),
      format: 'der',
      type: 'spki',
    });
    return verify(null, transcript, publicKey, signature);
  } catch {
    return false;
  }
}

export function verifyDeviceProof(
  identityPublicKey: Buffer,
  transcript: Buffer,
  signature: Buffer,
): boolean {
  return verifyEd25519Signature(identityPublicKey, transcript, signature);
}
