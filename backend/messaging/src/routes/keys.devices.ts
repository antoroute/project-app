import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

import { authenticatedDevice } from '../middlewares/deviceAuth.js';
import type { DbExecutor } from '../plugins/db.js';
import {
  createGroupDeviceKeyTranscript,
  verifyGroupDeviceKeyBinding,
} from '../security/groupDeviceKeyBinding.js';
import { decodeCanonicalBase64 } from '../security/deviceProof.js';
import { authenticatedUserId } from '../security/jwt.js';
import {
  CanonicalBase64Bytes32,
  CanonicalBase64Bytes64,
  KeyVersion,
  Uuid,
  strictObject,
} from '../schemas/input.schema.js';

const DeviceKey = strictObject(
  {
    deviceId: Uuid,
    pk_sig: CanonicalBase64Bytes32,
    pk_kem: CanonicalBase64Bytes32,
    key_version: KeyVersion,
    identityKeyVersion: KeyVersion,
    bindingSignature: CanonicalBase64Bytes64,
  },
);

const DirectoryEntry = Type.Object({
  userId: Type.String({ format: 'uuid' }),
  deviceId: Type.String({ format: 'uuid' }),
  pk_sig: Type.String(),
  pk_kem: Type.String(),
  key_version: Type.Integer(),
  status: Type.Union([
    Type.Literal('active'),
    Type.Literal('superseded'),
    Type.Literal('revoked'),
  ]),
});

type PublishOutcome =
  | { kind: 'published'; rotated: boolean; changed: boolean }
  | {
      kind:
        | 'forbidden'
        | 'device_not_active'
        | 'device_identity_changed'
        | 'invalid_key_binding'
        | 'device_revoked'
        | 'stale_key_version'
        | 'key_version_conflict'
        | 'key_version_gap';
    };

function sameBytes(left: unknown, right: Buffer): boolean {
  return Buffer.isBuffer(left) && left.equals(right);
}

const directoryQuery = `
  SELECT user_id AS "userId", device_id AS "deviceId",
         encode(pk_sig,'base64') AS "pk_sig",
         encode(pk_kem,'base64') AS "pk_kem",
         key_version AS "key_version", status
    FROM group_device_keys
   WHERE group_id = $1
     AND binding_signature IS NOT NULL
     AND octet_length(pk_sig) = 32
     AND octet_length(pk_kem) = 32
  UNION ALL
  SELECT user_id AS "userId", device_id AS "deviceId",
         encode(pk_sig,'base64') AS "pk_sig",
         encode(pk_kem,'base64') AS "pk_kem",
         key_version AS "key_version", status
    FROM group_device_key_history
   WHERE group_id = $1
  ORDER BY "userId", "deviceId", "key_version" DESC`;

export default async function routes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);
  app.addHook('preHandler', app.requireActiveDevice);

  app.get(
    '/api/keys/group/:groupId',
    {
      schema: {
        params: strictObject({ groupId: Uuid }),
        response: { 200: Type.Array(DirectoryEntry) },
      },
    },
    async (req, reply) => {
      const userId = authenticatedUserId(req);
      const { groupId } = req.params as { groupId: string };
      if (
        !(await app.services.acl.hasGroupPermission(
          userId,
          groupId,
          'keys:read',
        ))
      ) {
        return reply.code(403).send({ error: 'forbidden' });
      }
      return app.db.any(directoryQuery, [groupId]);
    },
  );

  app.get(
    '/api/keys/group/:groupId/my-devices',
    {
      schema: {
        params: strictObject({ groupId: Uuid }),
        response: { 200: Type.Array(DirectoryEntry) },
      },
    },
    async (req, reply) => {
      const userId = authenticatedUserId(req);
      const { groupId } = req.params as { groupId: string };
      if (
        !(await app.services.acl.hasGroupPermission(
          userId,
          groupId,
          'keys:manage-own',
        ))
      ) {
        return reply.code(403).send({ error: 'forbidden' });
      }
      return app.db.any(
        `SELECT * FROM (${directoryQuery}) directory
          WHERE "userId" = $2`,
        [groupId, userId],
      );
    },
  );

  app.post(
    '/api/keys/group/:groupId/devices',
    {
      schema: {
        params: strictObject({ groupId: Uuid }),
        body: DeviceKey,
        response: {
          201: Type.Object({
            ok: Type.Boolean(),
            keyVersion: Type.Integer(),
            rotated: Type.Boolean(),
          }),
        },
      },
    },
    async (req, reply) => {
      const userId = authenticatedUserId(req);
      const requestDevice = authenticatedDevice(req);
      const { groupId } = req.params as { groupId: string };
      const body = req.body as {
        deviceId: string;
        pk_sig: string;
        pk_kem: string;
        key_version: number;
        identityKeyVersion: number;
        bindingSignature: string;
      };
      if (
        body.deviceId !== requestDevice.deviceId ||
        body.identityKeyVersion !== requestDevice.identityKeyVersion
      ) {
        return reply.code(403).send({ error: 'device_identity_mismatch' });
      }

      let signaturePublicKey: Buffer;
      let kemPublicKey: Buffer;
      let bindingSignature: Buffer;
      try {
        signaturePublicKey = decodeCanonicalBase64(body.pk_sig, 32);
        kemPublicKey = decodeCanonicalBase64(body.pk_kem, 32);
        bindingSignature = decodeCanonicalBase64(body.bindingSignature, 64);
      } catch {
        return reply.code(400).send({ error: 'invalid_key_material' });
      }
      const transcript = createGroupDeviceKeyTranscript({
        accountId: userId,
        groupId,
        deviceId: body.deviceId,
        identityKeyVersion: body.identityKeyVersion,
        keyVersion: body.key_version,
        signaturePublicKey,
        kemPublicKey,
      });

      const outcome = await app.db.transaction(
        async (transaction: DbExecutor): Promise<PublishOutcome> => {
          const account = await transaction.oneOrNone(
            'SELECT id FROM users WHERE id = $1 FOR UPDATE',
            [userId],
          );
          if (!account) return { kind: 'forbidden' };

          const device = await transaction.oneOrNone(
            `SELECT identity_public_key, identity_key_version, status
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [userId, body.deviceId],
          );
          if (!device || device.status !== 'active') {
            return { kind: 'device_not_active' };
          }
          if (
            Number(device.identity_key_version) !==
              body.identityKeyVersion ||
            !sameBytes(
              device.identity_public_key,
              requestDevice.identityPublicKey,
            )
          ) {
            return { kind: 'device_identity_changed' };
          }
          if (
            !verifyGroupDeviceKeyBinding(
              device.identity_public_key as Buffer,
              transcript,
              bindingSignature,
            )
          ) {
            return { kind: 'invalid_key_binding' };
          }
          if (
            !(await app.services.acl.hasGroupPermission(
              userId,
              groupId,
              'keys:manage-own',
              { executor: transaction, lock: true },
            ))
          ) {
            return { kind: 'forbidden' };
          }

          const current = await transaction.oneOrNone(
            `SELECT pk_sig, pk_kem, key_version, identity_key_version,
                    binding_signature, status, created_at
               FROM group_device_keys
              WHERE group_id = $1 AND user_id = $2 AND device_id = $3
              FOR UPDATE`,
            [groupId, userId, body.deviceId],
          );
          if (!current) {
            if (body.key_version !== 1) return { kind: 'key_version_gap' };
            await transaction.none(
              `INSERT INTO group_device_keys(
                 group_id, user_id, device_id, pk_sig, pk_kem, key_version,
                 identity_key_version, binding_signature, status, updated_at
               ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'active',NOW())`,
              [
                groupId,
                userId,
                body.deviceId,
                signaturePublicKey,
                kemPublicKey,
                body.key_version,
                body.identityKeyVersion,
                bindingSignature,
              ],
            );
            return { kind: 'published', rotated: false, changed: true };
          }
          if (current.status === 'revoked') {
            return { kind: 'device_revoked' };
          }
          const currentVersion = Number(current.key_version);
          if (body.key_version < currentVersion) {
            return { kind: 'stale_key_version' };
          }
          const sameMaterial =
            sameBytes(current.pk_sig, signaturePublicKey) &&
            sameBytes(current.pk_kem, kemPublicKey);
          if (body.key_version === currentVersion) {
            if (!sameMaterial) return { kind: 'key_version_conflict' };
            const changed =
              current.status !== 'active' ||
              Number(current.identity_key_version) !==
                body.identityKeyVersion ||
              !sameBytes(current.binding_signature, bindingSignature);
            await transaction.none(
              `UPDATE group_device_keys
                  SET identity_key_version = $4, binding_signature = $5,
                      status = 'active', updated_at = NOW(), revoked_at = NULL
                WHERE group_id = $1 AND user_id = $2 AND device_id = $3`,
              [
                groupId,
                userId,
                body.deviceId,
                body.identityKeyVersion,
                bindingSignature,
              ],
            );
            return { kind: 'published', rotated: false, changed };
          }
          if (body.key_version !== currentVersion + 1) {
            return { kind: 'key_version_gap' };
          }

          if (current.status === 'active') {
            await transaction.none(
              `INSERT INTO group_device_key_history(
                 group_id, user_id, device_id, key_version,
                 identity_key_version, pk_sig, pk_kem, binding_signature,
                 status, activated_at
               ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'superseded',$9)
               ON CONFLICT DO NOTHING`,
              [
                groupId,
                userId,
                body.deviceId,
                currentVersion,
                current.identity_key_version,
                current.pk_sig,
                current.pk_kem,
                current.binding_signature,
                current.created_at,
              ],
            );
          }
          await transaction.none(
            `UPDATE group_device_keys
                SET pk_sig = $4, pk_kem = $5, key_version = $6,
                    identity_key_version = $7, binding_signature = $8,
                    status = 'active', created_at = NOW(), updated_at = NOW(),
                    revoked_at = NULL
              WHERE group_id = $1 AND user_id = $2 AND device_id = $3`,
            [
              groupId,
              userId,
              body.deviceId,
              signaturePublicKey,
              kemPublicKey,
              body.key_version,
              body.identityKeyVersion,
              bindingSignature,
            ],
          );
          return { kind: 'published', rotated: true, changed: true };
        },
        { isolationLevel: 'SERIALIZABLE' },
      );

      if (outcome.kind === 'published') {
        if (outcome.changed) {
          app.io.to(`group:${groupId}`).emit('device:key-directory-changed', {
            type: 'device:key-directory-changed',
            groupId,
            deviceId: body.deviceId,
            keyVersion: body.key_version,
          });
        }
        reply.code(201);
        return {
          ok: true,
          keyVersion: body.key_version,
          rotated: outcome.rotated,
        };
      }
      const statusCode =
        outcome.kind === 'forbidden' ||
        outcome.kind === 'device_not_active' ||
        outcome.kind === 'device_revoked' ||
        outcome.kind === 'invalid_key_binding'
          ? 403
          : 409;
      return reply.code(statusCode).send({ error: outcome.kind });
    },
  );

  app.delete(
    '/api/keys/group/:groupId/devices/:deviceId',
    {
      schema: {
        params: strictObject({ groupId: Uuid, deviceId: Uuid }),
      },
    },
    async (_req, reply) =>
      reply.code(409).send({ error: 'global_device_revocation_required' }),
  );
}
