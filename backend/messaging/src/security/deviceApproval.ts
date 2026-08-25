import { randomBytes, randomUUID } from 'node:crypto';

import { verifyEd25519Signature } from './deviceProof.js';

export const DEVICE_APPROVAL_DOMAIN = Buffer.from(
  'circlehaven/account-device-approval/v1\0',
  'ascii',
);
export const DEVICE_APPROVAL_TRANSCRIPT_LENGTH = 216;
export const DEVICE_APPROVAL_TTL_SECONDS = 5 * 60;
export const DEVICE_APPROVAL_MAX_OUTSTANDING = 8;
export const DEVICE_APPROVAL_MAX_PER_ACCOUNT_WINDOW = 20;
export const DEVICE_APPROVAL_MAX_PER_TARGET_WINDOW = 6;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type DeviceApprovalDecision = 'approve' | 'reject';

export interface DeviceApprovalTranscriptInput {
  challengeId: string;
  accountId: string;
  approverDeviceId: string;
  approverIdentityKeyVersion: number;
  approverIdentityPublicKey: Buffer;
  targetDeviceId: string;
  targetIdentityKeyVersion: number;
  targetIdentityPublicKey: Buffer;
  decision: DeviceApprovalDecision;
  challengeNonce: Buffer;
  expiresAtUnixSeconds: number;
}

export interface DeviceApprovalChallengeMaterial
  extends DeviceApprovalTranscriptInput {
  transcript: Buffer;
}

function uuidBytes(value: string): Buffer {
  if (!UUID_PATTERN.test(value)) throw new Error('invalid_uuid');
  return Buffer.from(value.replaceAll('-', ''), 'hex');
}

function keyVersionBytes(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 1 || value > 0xffffffff) {
    throw new Error('invalid_identity_key_version');
  }
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return bytes;
}

function identityKeyBytes(value: Buffer): Buffer {
  if (value.length !== 32) throw new Error('invalid_identity_public_key');
  return value;
}

function decisionBytes(value: DeviceApprovalDecision): Buffer {
  if (value === 'approve') return Buffer.from([1]);
  if (value === 'reject') return Buffer.from([2]);
  throw new Error('invalid_approval_decision');
}

export function buildDeviceApprovalTranscript(
  input: DeviceApprovalTranscriptInput,
): Buffer {
  if (input.approverDeviceId === input.targetDeviceId) {
    throw new Error('approval_device_conflict');
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
  const transcript = Buffer.concat([
    DEVICE_APPROVAL_DOMAIN,
    uuidBytes(input.challengeId),
    uuidBytes(input.accountId),
    uuidBytes(input.approverDeviceId),
    keyVersionBytes(input.approverIdentityKeyVersion),
    identityKeyBytes(input.approverIdentityPublicKey),
    uuidBytes(input.targetDeviceId),
    keyVersionBytes(input.targetIdentityKeyVersion),
    identityKeyBytes(input.targetIdentityPublicKey),
    decisionBytes(input.decision),
    input.challengeNonce,
    expiration,
  ]);
  if (transcript.length !== DEVICE_APPROVAL_TRANSCRIPT_LENGTH) {
    throw new Error('invalid_approval_transcript_length');
  }
  return transcript;
}

export function createDeviceApprovalChallengeMaterial(
  input: Omit<
    DeviceApprovalTranscriptInput,
    'challengeId' | 'challengeNonce' | 'expiresAtUnixSeconds'
  >,
  nowUnixSeconds = Math.floor(Date.now() / 1000),
): DeviceApprovalChallengeMaterial {
  const material = {
    ...input,
    challengeId: randomUUID(),
    challengeNonce: randomBytes(32),
    expiresAtUnixSeconds: nowUnixSeconds + DEVICE_APPROVAL_TTL_SECONDS,
  };
  return {
    ...material,
    transcript: buildDeviceApprovalTranscript(material),
  };
}

export function verifyDeviceApproval(
  approverIdentityPublicKey: Buffer,
  transcript: Buffer,
  signature: Buffer,
): boolean {
  return verifyEd25519Signature(
    approverIdentityPublicKey,
    transcript,
    signature,
  );
}
