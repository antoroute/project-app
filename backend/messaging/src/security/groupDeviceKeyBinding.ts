import { verifyEd25519Signature } from './deviceAccess.js';

export const GROUP_DEVICE_KEY_DOMAIN = Buffer.from(
  'circlehaven/group-device-key/v1\0',
  'ascii',
);
export const GROUP_DEVICE_KEY_TRANSCRIPT_LENGTH = 152;

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function uuidBytes(value: string): Buffer {
  if (!UUID_PATTERN.test(value)) throw new Error('invalid_uuid');
  return Buffer.from(value.replaceAll('-', ''), 'hex');
}

function versionBytes(value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 1 || value > 0xffffffff) {
    throw new Error('invalid_key_version');
  }
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return bytes;
}

export function createGroupDeviceKeyTranscript(input: {
  accountId: string;
  groupId: string;
  deviceId: string;
  identityKeyVersion: number;
  keyVersion: number;
  signaturePublicKey: Buffer;
  kemPublicKey: Buffer;
}): Buffer {
  if (
    input.signaturePublicKey.length !== 32 ||
    input.kemPublicKey.length !== 32
  ) {
    throw new Error('invalid_group_device_public_key');
  }
  const transcript = Buffer.concat([
    GROUP_DEVICE_KEY_DOMAIN,
    uuidBytes(input.accountId),
    uuidBytes(input.groupId),
    uuidBytes(input.deviceId),
    versionBytes(input.identityKeyVersion),
    versionBytes(input.keyVersion),
    input.signaturePublicKey,
    input.kemPublicKey,
  ]);
  if (transcript.length !== GROUP_DEVICE_KEY_TRANSCRIPT_LENGTH) {
    throw new Error('invalid_group_device_key_transcript_length');
  }
  return transcript;
}

export function verifyGroupDeviceKeyBinding(
  identityPublicKey: Buffer,
  transcript: Buffer,
  signature: Buffer,
): boolean {
  return verifyEd25519Signature(identityPublicKey, transcript, signature);
}
