// backend/messaging/src/schemas/messageV2.schema.ts
// Schéma strict pour POST /api/messages (v2 only)

import { Type } from '@sinclair/typebox';

export const WrappedKey = Type.Object({
  userId: Type.String({ format: 'uuid' }),
  deviceId: Type.String({ minLength: 1, maxLength: 128 }),
  wrap: Type.String({ contentEncoding: 'base64' }),
  nonce: Type.String({ contentEncoding: 'base64' }) // 12B
});

export const Alg = Type.Object({
  kem: Type.Literal('X25519'),
  kdf: Type.Literal('HKDF-SHA256'),
  aead: Type.Literal('AES-256-GCM'),
  sig: Type.Literal('Ed25519')
});

export const SendMessageV2Schema = Type.Object({
  v: Type.Literal(2),
  alg: Alg,
  groupId: Type.String({ format: 'uuid' }),
  convId: Type.String({ format: 'uuid' }),
  messageId: Type.String({ format: 'uuid' }),
  sentAt: Type.Number(),
  sender: Type.Object({
    userId: Type.String({ format: 'uuid' }),
    deviceId: Type.String({ minLength: 1, maxLength: 128 }),
    eph_pub: Type.String({ contentEncoding: 'base64' }),
    key_version: Type.Integer({ minimum: 1 })
  }),
  recipients: Type.Array(WrappedKey, { minItems: 1 }),
  iv: Type.String({ contentEncoding: 'base64' }),
  ciphertext: Type.String({ contentEncoding: 'base64' }),
  sig: Type.String({ contentEncoding: 'base64' }),
  salt: Type.String({ contentEncoding: 'base64' }) // 32B HKDF salt
});

export const SendMessageV2Reply = Type.Object({
  id: Type.String({ format: 'uuid' })
});
