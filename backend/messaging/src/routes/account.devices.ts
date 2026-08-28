import { FastifyInstance } from 'fastify';
import { Type } from '@sinclair/typebox';

import type { DbExecutor } from '../plugins/db.js';
import { authenticatedUserId } from '../security/jwt.js';
import {
  DEVICE_PROOF_MAX_OUTSTANDING,
  DEVICE_PROOF_MAX_PER_ACCOUNT_WINDOW,
  DEVICE_PROOF_MAX_PER_DEVICE_WINDOW,
  createDeviceChallengeMaterial,
  decodeCanonicalBase64,
  hashBootstrapGrant,
  verifyDeviceProof,
} from '../security/deviceProof.js';

const Platform = Type.Union([
  Type.Literal('android'),
  Type.Literal('ios'),
  Type.Literal('windows'),
  Type.Literal('macos'),
  Type.Literal('unknown'),
]);
const DeviceStatus = Type.Union([
  Type.Literal('pending'),
  Type.Literal('active'),
  Type.Literal('revoked'),
]);
const CanonicalEd25519PublicKey = Type.String({
  minLength: 44,
  maxLength: 44,
  pattern: '^[A-Za-z0-9+/]{43}=$',
});
const CanonicalEd25519Signature = Type.String({
  minLength: 88,
  maxLength: 88,
  pattern: '^[A-Za-z0-9+/]{86}==$',
});

const ChallengeRequest = Type.Object(
  {
    deviceId: Type.String({ format: 'uuid' }),
    identityPublicKey: CanonicalEd25519PublicKey,
    platform: Platform,
    deviceName: Type.String({ minLength: 1, maxLength: 64 }),
    bootstrapGrant: Type.Optional(
      Type.String({
        minLength: 43,
        maxLength: 43,
        pattern: '^[A-Za-z0-9_-]{43}$',
      }),
    ),
  },
  { additionalProperties: false },
);

const ProofRequest = Type.Object(
  { signature: CanonicalEd25519Signature },
  { additionalProperties: false },
);

type ChallengeOutcome =
  | { kind: 'issued' }
  | { kind: 'account_missing' }
  | { kind: 'device_revoked' }
  | { kind: 'device_identity_conflict' }
  | { kind: 'invalid_bootstrap_grant' }
  | { kind: 'too_many_challenges' };

type ProofOutcome =
  | {
      kind: 'verified';
      deviceId: string;
      status: 'pending' | 'active';
      bootstrap: boolean;
    }
  | {
      kind:
        | 'account_missing'
        | 'challenge_not_found'
        | 'challenge_consumed'
        | 'challenge_expired'
        | 'invalid_device_proof'
        | 'bootstrap_authorization_required'
        | 'device_identity_conflict'
        | 'identity_key_conflict'
        | 'device_revoked';
    };

function sameKey(left: unknown, right: Buffer): boolean {
  return Buffer.isBuffer(left) && left.length === 32 && left.equals(right);
}

function isoTimestamp(value: unknown): string | null {
  if (value == null) return null;
  if (value instanceof Date) return value.toISOString();
  return new Date(String(value)).toISOString();
}

export default async function accountDeviceRoutes(app: FastifyInstance) {
  app.addHook('onRequest', app.authenticate);

  app.post(
    '/api/devices/registrations/challenge',
    {
      schema: {
        body: ChallengeRequest,
        response: {
          201: Type.Object({
            challengeId: Type.String({ format: 'uuid' }),
            deviceId: Type.String({ format: 'uuid' }),
            challenge: Type.String(),
            transcript: Type.String(),
            expiresAt: Type.String({ format: 'date-time' }),
            algorithm: Type.Literal('Ed25519'),
          }),
        },
      },
    },
    async (request, reply) => {
      const accountId = authenticatedUserId(request);
      const body = request.body as {
        deviceId: string;
        identityPublicKey: string;
        platform: 'android' | 'ios' | 'windows' | 'macos' | 'unknown';
        deviceName: string;
        bootstrapGrant?: string;
      };
      const deviceName = body.deviceName.trim();
      if (deviceName.length === 0) {
        return reply.code(400).send({ error: 'invalid_device_name' });
      }

      let identityPublicKey: Buffer;
      let bootstrapGrantHash: Buffer | null = null;
      try {
        identityPublicKey = decodeCanonicalBase64(body.identityPublicKey, 32);
      } catch {
        return reply.code(400).send({ error: 'invalid_identity_public_key' });
      }
      if (body.bootstrapGrant !== undefined) {
        try {
          bootstrapGrantHash = hashBootstrapGrant(body.bootstrapGrant);
        } catch {
          return reply.code(400).send({ error: 'invalid_bootstrap_grant' });
        }
      }

      const challenge = createDeviceChallengeMaterial(
        accountId,
        body.deviceId,
        identityPublicKey,
      );
      const outcome = await app.db.transaction(
        async (transaction: DbExecutor): Promise<ChallengeOutcome> => {
          const account = await transaction.oneOrNone(
            'SELECT id FROM users WHERE id = $1 FOR UPDATE',
            [accountId],
          );
          if (!account) return { kind: 'account_missing' };

          const existingDevice = await transaction.oneOrNone(
            `SELECT status, identity_public_key
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, body.deviceId],
          );
          if (existingDevice?.status === 'revoked') {
            return { kind: 'device_revoked' };
          }
          if (
            existingDevice &&
            !sameKey(existingDevice.identity_public_key, identityPublicKey)
          ) {
            return { kind: 'device_identity_conflict' };
          }

          let bootstrapGrantId: string | null = null;
          if (bootstrapGrantHash) {
            const grant = await transaction.oneOrNone(
              `SELECT id
                 FROM device_bootstrap_grants
                WHERE user_id = $1 AND token_hash = $2
                  AND consumed_at IS NULL AND expires_at > NOW()
                FOR UPDATE`,
              [accountId, bootstrapGrantHash],
            );
            if (!grant) return { kind: 'invalid_bootstrap_grant' };
            bootstrapGrantId = grant.id as string;
          }

          await transaction.none(
            `DELETE FROM device_registration_challenges
              WHERE user_id = $1
                AND COALESCE(consumed_at, expires_at) < NOW() - INTERVAL '7 days'`,
            [accountId],
          );

          const recent = await transaction.one(
            `SELECT
               COUNT(*) FILTER (
                 WHERE created_at > NOW() - INTERVAL '10 minutes'
               )::int AS account_count,
               COUNT(*) FILTER (
                 WHERE device_id = $2
                   AND created_at > NOW() - INTERVAL '10 minutes'
               )::int AS device_count
             FROM device_registration_challenges
             WHERE user_id = $1`,
            [accountId, body.deviceId],
          );
          if (
            Number(recent.account_count) >=
              DEVICE_PROOF_MAX_PER_ACCOUNT_WINDOW ||
            Number(recent.device_count) >= DEVICE_PROOF_MAX_PER_DEVICE_WINDOW
          ) {
            return { kind: 'too_many_challenges' };
          }

          const outstanding = await transaction.one(
            `SELECT COUNT(*)::int AS count
               FROM device_registration_challenges
              WHERE user_id = $1
                AND device_id <> $2
                AND consumed_at IS NULL
                AND expires_at > NOW()`,
            [accountId, body.deviceId],
          );
          if (Number(outstanding.count) >= DEVICE_PROOF_MAX_OUTSTANDING) {
            return { kind: 'too_many_challenges' };
          }

          await transaction.none(
            `UPDATE device_registration_challenges
                SET consumed_at = NOW(), result = 'superseded'
              WHERE user_id = $1 AND device_id = $2
                AND consumed_at IS NULL`,
            [accountId, body.deviceId],
          );

          await transaction.none(
            `INSERT INTO device_registration_challenges(
               id, user_id, device_id, identity_public_key, platform,
               device_name, challenge_nonce, transcript, bootstrap_grant_id,
               expires_at
             )
             VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,to_timestamp($10))`,
            [
              challenge.challengeId,
              accountId,
              body.deviceId,
              identityPublicKey,
              body.platform,
              deviceName,
              challenge.challengeNonce,
              challenge.transcript,
              bootstrapGrantId,
              challenge.expiresAtUnixSeconds,
            ],
          );
          return { kind: 'issued' };
        },
        { isolationLevel: 'SERIALIZABLE' },
      );

      if (outcome.kind === 'account_missing') {
        return reply.code(401).send({ error: 'unauthorized' });
      }
      if (outcome.kind === 'device_revoked') {
        return reply.code(403).send({ error: 'device_revoked' });
      }
      if (outcome.kind === 'device_identity_conflict') {
        return reply.code(409).send({ error: 'device_identity_conflict' });
      }
      if (outcome.kind === 'invalid_bootstrap_grant') {
        return reply.code(403).send({ error: 'invalid_bootstrap_grant' });
      }
      if (outcome.kind === 'too_many_challenges') {
        return reply.code(429).send({ error: 'too_many_device_challenges' });
      }

      reply.code(201);
      return {
        challengeId: challenge.challengeId,
        deviceId: body.deviceId,
        challenge: challenge.challengeNonce.toString('base64'),
        transcript: challenge.transcript.toString('base64'),
        expiresAt: new Date(
          challenge.expiresAtUnixSeconds * 1000,
        ).toISOString(),
        algorithm: 'Ed25519' as const,
      };
    },
  );

  app.post(
    '/api/devices/registrations/:challengeId/proof',
    {
      schema: {
        params: Type.Object({
          challengeId: Type.String({ format: 'uuid' }),
        }),
        body: ProofRequest,
        response: {
          201: Type.Object({
            deviceId: Type.String({ format: 'uuid' }),
            status: Type.Union([
              Type.Literal('pending'),
              Type.Literal('active'),
            ]),
            bootstrap: Type.Boolean(),
          }),
        },
      },
    },
    async (request, reply) => {
      const accountId = authenticatedUserId(request);
      const { challengeId } = request.params as { challengeId: string };
      const { signature: signatureBase64 } = request.body as {
        signature: string;
      };
      let signature: Buffer;
      try {
        signature = decodeCanonicalBase64(signatureBase64, 64);
      } catch {
        return reply.code(400).send({ error: 'invalid_signature_encoding' });
      }

      const outcome = await app.db.transaction(
        async (transaction: DbExecutor): Promise<ProofOutcome> => {
          const account = await transaction.oneOrNone(
            'SELECT id FROM users WHERE id = $1 FOR UPDATE',
            [accountId],
          );
          if (!account) return { kind: 'account_missing' };

          const challenge = await transaction.oneOrNone(
            `SELECT device_id, identity_public_key, platform, device_name,
                    transcript, bootstrap_grant_id, consumed_at,
                    expires_at <= NOW() AS expired
               FROM device_registration_challenges
              WHERE id = $1 AND user_id = $2
              FOR UPDATE`,
            [challengeId, accountId],
          );
          if (!challenge) return { kind: 'challenge_not_found' };
          if (challenge.consumed_at) return { kind: 'challenge_consumed' };
          if (challenge.expired) {
            await transaction.none(
              `UPDATE device_registration_challenges
                  SET consumed_at = NOW(), result = 'expired'
                WHERE id = $1`,
              [challengeId],
            );
            return { kind: 'challenge_expired' };
          }

          const identityPublicKey = challenge.identity_public_key as Buffer;
          const transcript = challenge.transcript as Buffer;
          if (!verifyDeviceProof(identityPublicKey, transcript, signature)) {
            await transaction.none(
              `UPDATE device_registration_challenges
                  SET consumed_at = NOW(), result = 'invalid_signature'
                WHERE id = $1`,
              [challengeId],
            );
            return { kind: 'invalid_device_proof' };
          }

          const existingDevice = await transaction.oneOrNone(
            `SELECT status, identity_public_key, activated_at
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, challenge.device_id],
          );
          if (
            existingDevice &&
            !sameKey(existingDevice.identity_public_key, identityPublicKey)
          ) {
            await transaction.none(
              `UPDATE device_registration_challenges
                  SET consumed_at = NOW(), result = 'device_identity_conflict'
                WHERE id = $1`,
              [challengeId],
            );
            return { kind: 'device_identity_conflict' };
          }
          if (existingDevice?.status === 'revoked') {
            await transaction.none(
              `UPDATE device_registration_challenges
                  SET consumed_at = NOW(), result = 'device_revoked'
                WHERE id = $1`,
              [challengeId],
            );
            return { kind: 'device_revoked' };
          }

          const keyOwner = await transaction.oneOrNone(
            `SELECT device_id
               FROM account_devices
              WHERE user_id = $1 AND identity_public_key = $2
              FOR UPDATE`,
            [accountId, identityPublicKey],
          );
          if (keyOwner && keyOwner.device_id !== challenge.device_id) {
            await transaction.none(
              `UPDATE device_registration_challenges
                  SET consumed_at = NOW(), result = 'identity_key_conflict'
                WHERE id = $1`,
              [challengeId],
            );
            return { kind: 'identity_key_conflict' };
          }

          const trustHistory = await transaction.one(
            `SELECT EXISTS(
               SELECT 1 FROM account_devices
                WHERE user_id = $1 AND activated_at IS NOT NULL
             ) AS has_ever_activated`,
            [accountId],
          );
          const bootstrap = !Boolean(trustHistory.has_ever_activated);
          const status = bootstrap ? 'active' : 'pending';

          if (bootstrap) {
            const grant = challenge.bootstrap_grant_id
              ? await transaction.oneOrNone(
                  `UPDATE device_bootstrap_grants
                      SET consumed_at = NOW()
                    WHERE id = $1 AND user_id = $2
                      AND consumed_at IS NULL AND expires_at > NOW()
                    RETURNING id`,
                  [challenge.bootstrap_grant_id, accountId],
                )
              : null;
            if (!grant) {
              await transaction.none(
                `UPDATE device_registration_challenges
                    SET consumed_at = NOW(),
                        result = 'bootstrap_authorization_required'
                  WHERE id = $1`,
                [challengeId],
              );
              return { kind: 'bootstrap_authorization_required' };
            }
          }

          if (existingDevice) {
            await transaction.none(
              `UPDATE account_devices
                  SET platform = $3,
                      device_name = $4,
                      proof_verified_at = NOW(),
                      status = CASE WHEN $5 THEN 'active' ELSE status END,
                      activated_at = CASE
                        WHEN $5 THEN COALESCE(activated_at, NOW())
                        ELSE activated_at
                      END,
                      updated_at = NOW()
                WHERE user_id = $1 AND device_id = $2`,
              [
                accountId,
                challenge.device_id,
                challenge.platform,
                challenge.device_name,
                bootstrap,
              ],
            );
          } else {
            await transaction.none(
              `INSERT INTO account_devices(
                 user_id, device_id, identity_public_key, identity_key_version,
                 platform, device_name, status, proof_verified_at, activated_at
               )
               VALUES($1,$2,$3,1,$4,$5,$6,NOW(),
                      CASE WHEN $6 = 'active' THEN NOW() ELSE NULL END)`,
              [
                accountId,
                challenge.device_id,
                identityPublicKey,
                challenge.platform,
                challenge.device_name,
                status,
              ],
            );
          }

          const effectiveStatus =
            existingDevice?.status === 'active' ? 'active' : status;
          await transaction.none(
            `UPDATE device_registration_challenges
                SET consumed_at = NOW(), result = $2
              WHERE id = $1`,
            [challengeId, effectiveStatus],
          );
          return {
            kind: 'verified',
            deviceId: challenge.device_id as string,
            status: effectiveStatus,
            bootstrap: bootstrap && effectiveStatus === 'active',
          };
        },
        { isolationLevel: 'SERIALIZABLE' },
      );

      switch (outcome.kind) {
        case 'verified':
          reply.code(201);
          return {
            deviceId: outcome.deviceId,
            status: outcome.status,
            bootstrap: outcome.bootstrap,
          };
        case 'account_missing':
          return reply.code(401).send({ error: 'unauthorized' });
        case 'challenge_not_found':
          return reply.code(404).send({ error: 'device_challenge_not_found' });
        case 'challenge_consumed':
          return reply.code(409).send({ error: 'device_challenge_consumed' });
        case 'challenge_expired':
          return reply.code(410).send({ error: 'device_challenge_expired' });
        case 'invalid_device_proof':
          return reply.code(403).send({ error: 'invalid_device_proof' });
        case 'bootstrap_authorization_required':
          return reply
            .code(403)
            .send({ error: 'bootstrap_authorization_required' });
        case 'device_identity_conflict':
          return reply.code(409).send({ error: 'device_identity_conflict' });
        case 'identity_key_conflict':
          return reply.code(409).send({ error: 'identity_key_conflict' });
        case 'device_revoked':
          return reply.code(403).send({ error: 'device_revoked' });
      }
    },
  );

  app.get(
    '/api/devices',
    {
      preHandler: app.identifyDevice,
      schema: {
        response: {
          200: Type.Array(
            Type.Object({
              deviceId: Type.String({ format: 'uuid' }),
              identityPublicKey: Type.String(),
              identityKeyVersion: Type.Integer(),
              platform: Platform,
              deviceName: Type.String(),
              status: DeviceStatus,
              proofVerifiedAt: Type.String({ format: 'date-time' }),
              activatedAt: Type.Union([
                Type.String({ format: 'date-time' }),
                Type.Null(),
              ]),
              revokedAt: Type.Union([
                Type.String({ format: 'date-time' }),
                Type.Null(),
              ]),
              createdAt: Type.String({ format: 'date-time' }),
              updatedAt: Type.String({ format: 'date-time' }),
            }),
          ),
        },
      },
    },
    async (request) => {
      const accountId = authenticatedUserId(request);
      const current = request.accountDevice!;
      const rows = await app.db.any(
        `SELECT device_id, identity_public_key, identity_key_version,
                platform, device_name, status, proof_verified_at,
                activated_at, revoked_at, created_at, updated_at
           FROM account_devices
          WHERE user_id = $1
            AND ($2::text = 'active' OR device_id = $3)
          ORDER BY created_at ASC`,
        [accountId, current.status, current.deviceId],
      );
      return rows.map((row) => ({
        deviceId: row.device_id,
        identityPublicKey: (row.identity_public_key as Buffer).toString(
          'base64',
        ),
        identityKeyVersion: row.identity_key_version,
        platform: row.platform,
        deviceName: row.device_name,
        status: row.status,
        proofVerifiedAt: isoTimestamp(row.proof_verified_at)!,
        activatedAt: isoTimestamp(row.activated_at),
        revokedAt: isoTimestamp(row.revoked_at),
        createdAt: isoTimestamp(row.created_at)!,
        updatedAt: isoTimestamp(row.updated_at)!,
      }));
    },
  );
}
