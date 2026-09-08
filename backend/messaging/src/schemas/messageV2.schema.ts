// backend/messaging/src/schemas/messageV2.schema.ts
// Schéma strict pour POST /api/messages (v2 only)

import { Type } from '@sinclair/typebox';
import {
  CanonicalBase64Bytes12,
  CanonicalBase64Bytes32,
  CanonicalBase64Bytes48,
  CanonicalBase64Bytes64,
  CanonicalCiphertext,
  KeyVersion,
  MAX_MESSAGE_RECIPIENTS,
  Uuid,
  strictObject,
} from './input.schema.js';

export const WrappedKey = strictObject({
  userId: Uuid,
  deviceId: Uuid,
  key_version: KeyVersion,
  wrap: CanonicalBase64Bytes48,
  nonce: CanonicalBase64Bytes12,
});

export const Alg = strictObject({
  kem: Type.Literal('X25519'),
  kdf: Type.Literal('HKDF-SHA256'),
  aead: Type.Literal('AES-256-GCM'),
  sig: Type.Literal('Ed25519')
});

export const SendMessageV2Schema = strictObject({
  v: Type.Literal(2),
  alg: Alg,
  groupId: Uuid,
  convId: Uuid,
  messageId: Uuid,
  sentAt: Type.Integer({ minimum: 0, maximum: 4102444800 }),
  sender: strictObject({
    userId: Uuid,
    deviceId: Uuid,
    eph_pub: CanonicalBase64Bytes32,
    key_version: KeyVersion,
  }),
  recipients: Type.Array(WrappedKey, {
    minItems: 1,
    maxItems: MAX_MESSAGE_RECIPIENTS,
  }),
  iv: CanonicalBase64Bytes12,
  ciphertext: CanonicalCiphertext,
  sig: CanonicalBase64Bytes64,
  salt: CanonicalBase64Bytes32,
});

export const SendMessageV2Reply = Type.Object({
  id: Type.String({ format: 'uuid' })
});
