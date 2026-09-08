import { Type, type TProperties } from '@sinclair/typebox';

export const MESSAGING_BODY_LIMIT_BYTES = 256 * 1024;
export const SOCKET_PAYLOAD_LIMIT_BYTES = 16 * 1024;
export const MAX_CONVERSATION_MEMBERS = 128;
export const MAX_MESSAGE_RECIPIENTS = 256;
export const MAX_SOCKET_BATCH_CONVERSATIONS = 100;
export const MAX_MESSAGE_CIPHERTEXT_BYTES = 64 * 1024;
export const MAX_KEY_VERSION = 0xffffffff;

export const Uuid = Type.String({ format: 'uuid' });
export const KeyVersion = Type.Integer({
  minimum: 1,
  maximum: MAX_KEY_VERSION,
});

export const CanonicalBase64Bytes12 = Type.String({
  minLength: 16,
  maxLength: 16,
  pattern: '^[A-Za-z0-9+/]{16}$',
});
export const CanonicalBase64Bytes32 = Type.String({
  minLength: 44,
  maxLength: 44,
  pattern: '^[A-Za-z0-9+/]{43}=$',
});
export const CanonicalBase64Bytes48 = Type.String({
  minLength: 64,
  maxLength: 64,
  pattern: '^[A-Za-z0-9+/]{64}$',
});
export const CanonicalBase64Bytes64 = Type.String({
  minLength: 88,
  maxLength: 88,
  pattern: '^[A-Za-z0-9+/]{86}==$',
});

export const CanonicalCiphertext = Type.String({
  minLength: 24,
  maxLength: Math.ceil(MAX_MESSAGE_CIPHERTEXT_BYTES / 3) * 4,
  pattern:
    '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
});

export function boundedDisplayName(minLength = 1) {
  return Type.String({
    minLength,
    maxLength: 64,
    pattern: '^(?!\\s)(?!.*\\s$)[^\\u0000-\\u001F\\u007F]+$',
  });
}

export function strictObject<T extends TProperties>(properties: T) {
  return Type.Object(properties, { additionalProperties: false });
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function parseStrictConversationEvent(data: unknown): string | null {
  if (
    typeof data !== 'object' ||
    data === null ||
    Array.isArray(data) ||
    Object.keys(data).length !== 1
  ) {
    return null;
  }
  const convId = (data as { convId?: unknown }).convId;
  return typeof convId === 'string' && UUID_PATTERN.test(convId)
    ? convId
    : null;
}

export function parseStrictConversationBatch(data: unknown): string[] | null {
  if (
    typeof data !== 'object' ||
    data === null ||
    Array.isArray(data) ||
    Object.keys(data).length !== 1
  ) {
    return null;
  }
  const convIds = (data as { convIds?: unknown }).convIds;
  if (
    !Array.isArray(convIds) ||
    convIds.length === 0 ||
    convIds.length > MAX_SOCKET_BATCH_CONVERSATIONS ||
    convIds.some((value) => typeof value !== 'string' || !UUID_PATTERN.test(value))
  ) {
    return null;
  }
  const unique = new Set(convIds as string[]);
  return unique.size === convIds.length ? [...unique] : null;
}
