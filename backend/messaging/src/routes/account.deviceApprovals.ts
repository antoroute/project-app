import { Type } from '@sinclair/typebox';
import { FastifyInstance } from 'fastify';

import type { DbExecutor } from '../plugins/db.js';
import {
  DEVICE_APPROVAL_MAX_OUTSTANDING,
  DEVICE_APPROVAL_MAX_PER_ACCOUNT_WINDOW,
  DEVICE_APPROVAL_MAX_PER_TARGET_WINDOW,
  createDeviceApprovalChallengeMaterial,
  verifyDeviceApproval,
} from '../security/deviceApproval.js';
import type {
  DeviceApprovalChallengeMaterial,
  DeviceApprovalDecision,
} from '../security/deviceApproval.js';
import { decodeCanonicalBase64 } from '../security/deviceProof.js';
import { authenticatedUserId } from '../security/jwt.js';

const Platform = Type.Union([
  Type.Literal('android'),
  Type.Literal('ios'),
  Type.Literal('windows'),
  Type.Literal('macos'),
  Type.Literal('unknown'),
]);
const ApprovalDecision = Type.Union([
  Type.Literal('approve'),
  Type.Literal('reject'),
]);
const CanonicalEd25519Signature = Type.String({
  minLength: 88,
  maxLength: 88,
  pattern: '^[A-Za-z0-9+/]{86}==$',
});

const ApprovalChallengeRequest = Type.Object(
  {
    approverDeviceId: Type.String({ format: 'uuid' }),
    decision: ApprovalDecision,
  },
  { additionalProperties: false },
);
const ApprovalProofRequest = Type.Object(
  { signature: CanonicalEd25519Signature },
  { additionalProperties: false },
);

interface ApprovalTarget {
  deviceId: string;
  identityPublicKey: string;
  identityKeyVersion: number;
  platform: 'android' | 'ios' | 'windows' | 'macos' | 'unknown';
  deviceName: string;
}

type ApprovalChallengeOutcome =
  | {
      kind: 'issued';
      material: DeviceApprovalChallengeMaterial;
      target: ApprovalTarget;
    }
  | {
      kind:
        | 'account_missing'
        | 'approver_device_not_active'
        | 'target_device_not_found'
        | 'target_device_not_pending'
        | 'too_many_approval_challenges';
    };

type ApprovalProofOutcome =
  | {
      kind: 'decided';
      targetDeviceId: string;
      approverDeviceId: string;
      decision: DeviceApprovalDecision;
      status: 'active' | 'revoked';
    }
  | {
      kind:
        | 'account_missing'
        | 'approval_challenge_not_found'
        | 'approval_challenge_consumed'
        | 'approval_challenge_expired'
        | 'invalid_device_approval'
        | 'approver_device_not_active'
        | 'approver_identity_changed'
        | 'target_device_not_pending'
        | 'target_identity_changed';
    };

function sameKey(left: unknown, right: Buffer): boolean {
  return Buffer.isBuffer(left) && left.length === 32 && left.equals(right);
}

async function consumeChallenge(
  transaction: DbExecutor,
  challengeId: string,
  result: string,
): Promise<void> {
  await transaction.none(
    `UPDATE device_approval_challenges
        SET consumed_at = NOW(), result = $2
      WHERE id = $1`,
    [challengeId, result],
  );
}

export default async function accountDeviceApprovalRoutes(
  app: FastifyInstance,
) {
  app.addHook('onRequest', app.authenticate);

  app.post(
    '/api/devices/:targetDeviceId/approvals/challenge',
    {
      schema: {
        params: Type.Object({
          targetDeviceId: Type.String({ format: 'uuid' }),
        }),
        body: ApprovalChallengeRequest,
        response: {
          201: Type.Object({
            challengeId: Type.String({ format: 'uuid' }),
            approverDeviceId: Type.String({ format: 'uuid' }),
            targetDeviceId: Type.String({ format: 'uuid' }),
            decision: ApprovalDecision,
            transcript: Type.String(),
            expiresAt: Type.String({ format: 'date-time' }),
            algorithm: Type.Literal('Ed25519'),
            target: Type.Object({
              deviceId: Type.String({ format: 'uuid' }),
              identityPublicKey: Type.String(),
              identityKeyVersion: Type.Integer({ minimum: 1 }),
              platform: Platform,
              deviceName: Type.String(),
            }),
          }),
        },
      },
    },
    async (request, reply) => {
      const accountId = authenticatedUserId(request);
      const { targetDeviceId } = request.params as { targetDeviceId: string };
      const { approverDeviceId, decision } = request.body as {
        approverDeviceId: string;
        decision: DeviceApprovalDecision;
      };

      const outcome = await app.db.transaction(
        async (
          transaction: DbExecutor,
        ): Promise<ApprovalChallengeOutcome> => {
          const account = await transaction.oneOrNone(
            'SELECT id FROM users WHERE id = $1 FOR UPDATE',
            [accountId],
          );
          if (!account) return { kind: 'account_missing' };

          const approver = await transaction.oneOrNone(
            `SELECT device_id, identity_public_key, identity_key_version, status
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, approverDeviceId],
          );
          if (!approver || approver.status !== 'active') {
            return { kind: 'approver_device_not_active' };
          }

          const target = await transaction.oneOrNone(
            `SELECT device_id, identity_public_key, identity_key_version,
                    platform, device_name, status
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, targetDeviceId],
          );
          if (!target) return { kind: 'target_device_not_found' };
          if (target.status !== 'pending') {
            return { kind: 'target_device_not_pending' };
          }

          await transaction.none(
            `DELETE FROM device_approval_challenges
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
                 WHERE target_device_id = $2
                   AND created_at > NOW() - INTERVAL '10 minutes'
               )::int AS target_count
             FROM device_approval_challenges
             WHERE user_id = $1`,
            [accountId, targetDeviceId],
          );
          if (
            Number(recent.account_count) >=
              DEVICE_APPROVAL_MAX_PER_ACCOUNT_WINDOW ||
            Number(recent.target_count) >=
              DEVICE_APPROVAL_MAX_PER_TARGET_WINDOW
          ) {
            return { kind: 'too_many_approval_challenges' };
          }

          const outstanding = await transaction.one(
            `SELECT COUNT(*)::int AS count
               FROM device_approval_challenges
              WHERE user_id = $1
                AND NOT (
                  approver_device_id = $2 AND target_device_id = $3
                )
                AND consumed_at IS NULL AND expires_at > NOW()`,
            [accountId, approverDeviceId, targetDeviceId],
          );
          if (Number(outstanding.count) >= DEVICE_APPROVAL_MAX_OUTSTANDING) {
            return { kind: 'too_many_approval_challenges' };
          }

          await transaction.none(
            `UPDATE device_approval_challenges
                SET consumed_at = NOW(), result = 'superseded'
              WHERE user_id = $1 AND approver_device_id = $2
                AND target_device_id = $3 AND consumed_at IS NULL`,
            [accountId, approverDeviceId, targetDeviceId],
          );

          const material = createDeviceApprovalChallengeMaterial({
            accountId,
            approverDeviceId,
            approverIdentityKeyVersion: Number(
              approver.identity_key_version,
            ),
            approverIdentityPublicKey:
              approver.identity_public_key as Buffer,
            targetDeviceId,
            targetIdentityKeyVersion: Number(target.identity_key_version),
            targetIdentityPublicKey: target.identity_public_key as Buffer,
            decision,
          });
          await transaction.none(
            `INSERT INTO device_approval_challenges(
               id, user_id, approver_device_id,
               approver_identity_key_version, approver_identity_public_key,
               target_device_id, target_identity_key_version,
               target_identity_public_key, decision, challenge_nonce,
               transcript, expires_at
             )
             VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,to_timestamp($12))`,
            [
              material.challengeId,
              accountId,
              approverDeviceId,
              material.approverIdentityKeyVersion,
              material.approverIdentityPublicKey,
              targetDeviceId,
              material.targetIdentityKeyVersion,
              material.targetIdentityPublicKey,
              decision,
              material.challengeNonce,
              material.transcript,
              material.expiresAtUnixSeconds,
            ],
          );
          return {
            kind: 'issued',
            material,
            target: {
              deviceId: targetDeviceId,
              identityPublicKey: (
                target.identity_public_key as Buffer
              ).toString('base64'),
              identityKeyVersion: Number(target.identity_key_version),
              platform: target.platform as ApprovalTarget['platform'],
              deviceName: target.device_name as string,
            },
          };
        },
        { isolationLevel: 'SERIALIZABLE' },
      );

      switch (outcome.kind) {
        case 'issued':
          reply.code(201);
          return {
            challengeId: outcome.material.challengeId,
            approverDeviceId,
            targetDeviceId,
            decision,
            transcript: outcome.material.transcript.toString('base64'),
            expiresAt: new Date(
              outcome.material.expiresAtUnixSeconds * 1000,
            ).toISOString(),
            algorithm: 'Ed25519' as const,
            target: outcome.target,
          };
        case 'account_missing':
          return reply.code(401).send({ error: 'unauthorized' });
        case 'approver_device_not_active':
          return reply
            .code(403)
            .send({ error: 'approver_device_not_active' });
        case 'target_device_not_found':
          return reply.code(404).send({ error: 'target_device_not_found' });
        case 'target_device_not_pending':
          return reply.code(409).send({ error: 'target_device_not_pending' });
        case 'too_many_approval_challenges':
          return reply
            .code(429)
            .send({ error: 'too_many_device_approval_challenges' });
      }
    },
  );

  app.post(
    '/api/devices/approvals/:challengeId/decision',
    {
      schema: {
        params: Type.Object({
          challengeId: Type.String({ format: 'uuid' }),
        }),
        body: ApprovalProofRequest,
        response: {
          200: Type.Object({
            targetDeviceId: Type.String({ format: 'uuid' }),
            approverDeviceId: Type.String({ format: 'uuid' }),
            decision: ApprovalDecision,
            status: Type.Union([
              Type.Literal('active'),
              Type.Literal('revoked'),
            ]),
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
        async (transaction: DbExecutor): Promise<ApprovalProofOutcome> => {
          const account = await transaction.oneOrNone(
            'SELECT id FROM users WHERE id = $1 FOR UPDATE',
            [accountId],
          );
          if (!account) return { kind: 'account_missing' };

          const challenge = await transaction.oneOrNone(
            `SELECT approver_device_id, approver_identity_key_version,
                    approver_identity_public_key, target_device_id,
                    target_identity_key_version, target_identity_public_key,
                    decision, transcript, consumed_at,
                    expires_at <= NOW() AS expired
               FROM device_approval_challenges
              WHERE id = $1 AND user_id = $2
              FOR UPDATE`,
            [challengeId, accountId],
          );
          if (!challenge) return { kind: 'approval_challenge_not_found' };
          if (challenge.consumed_at) {
            return { kind: 'approval_challenge_consumed' };
          }
          if (challenge.expired) {
            await consumeChallenge(transaction, challengeId, 'expired');
            return { kind: 'approval_challenge_expired' };
          }

          const approverIdentityPublicKey =
            challenge.approver_identity_public_key as Buffer;
          if (
            !verifyDeviceApproval(
              approverIdentityPublicKey,
              challenge.transcript as Buffer,
              signature,
            )
          ) {
            await consumeChallenge(
              transaction,
              challengeId,
              'invalid_signature',
            );
            return { kind: 'invalid_device_approval' };
          }

          const approver = await transaction.oneOrNone(
            `SELECT status, identity_public_key, identity_key_version
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, challenge.approver_device_id],
          );
          if (!approver || approver.status !== 'active') {
            await consumeChallenge(
              transaction,
              challengeId,
              'approver_not_active',
            );
            return { kind: 'approver_device_not_active' };
          }
          if (
            Number(approver.identity_key_version) !==
              Number(challenge.approver_identity_key_version) ||
            !sameKey(approver.identity_public_key, approverIdentityPublicKey)
          ) {
            await consumeChallenge(
              transaction,
              challengeId,
              'approver_identity_changed',
            );
            return { kind: 'approver_identity_changed' };
          }

          const target = await transaction.oneOrNone(
            `SELECT status, identity_public_key, identity_key_version
               FROM account_devices
              WHERE user_id = $1 AND device_id = $2
              FOR UPDATE`,
            [accountId, challenge.target_device_id],
          );
          if (!target || target.status !== 'pending') {
            await consumeChallenge(
              transaction,
              challengeId,
              'target_not_pending',
            );
            return { kind: 'target_device_not_pending' };
          }
          if (
            Number(target.identity_key_version) !==
              Number(challenge.target_identity_key_version) ||
            !sameKey(
              target.identity_public_key,
              challenge.target_identity_public_key as Buffer,
            )
          ) {
            await consumeChallenge(
              transaction,
              challengeId,
              'target_identity_changed',
            );
            return { kind: 'target_identity_changed' };
          }

          const decision = challenge.decision as DeviceApprovalDecision;
          const status = decision === 'approve' ? 'active' : 'revoked';
          if (decision === 'approve') {
            await transaction.none(
              `UPDATE account_devices
                  SET status = 'active', activated_at = NOW(),
                      revoked_at = NULL, updated_at = NOW()
                WHERE user_id = $1 AND device_id = $2`,
              [accountId, challenge.target_device_id],
            );
          } else {
            await transaction.none(
              `UPDATE account_devices
                  SET status = 'revoked', revoked_at = NOW(), updated_at = NOW()
                WHERE user_id = $1 AND device_id = $2`,
              [accountId, challenge.target_device_id],
            );
          }

          await transaction.none(
            `UPDATE device_approval_challenges
                SET consumed_at = NOW(), result = 'superseded_by_decision'
              WHERE user_id = $1 AND target_device_id = $2
                AND id <> $3 AND consumed_at IS NULL`,
            [accountId, challenge.target_device_id, challengeId],
          );
          await consumeChallenge(
            transaction,
            challengeId,
            decision === 'approve' ? 'approved' : 'rejected',
          );
          return {
            kind: 'decided',
            targetDeviceId: challenge.target_device_id as string,
            approverDeviceId: challenge.approver_device_id as string,
            decision,
            status,
          };
        },
        { isolationLevel: 'SERIALIZABLE' },
      );

      switch (outcome.kind) {
        case 'decided':
          return {
            targetDeviceId: outcome.targetDeviceId,
            approverDeviceId: outcome.approverDeviceId,
            decision: outcome.decision,
            status: outcome.status,
          };
        case 'account_missing':
          return reply.code(401).send({ error: 'unauthorized' });
        case 'approval_challenge_not_found':
          return reply
            .code(404)
            .send({ error: 'device_approval_challenge_not_found' });
        case 'approval_challenge_consumed':
          return reply
            .code(409)
            .send({ error: 'device_approval_challenge_consumed' });
        case 'approval_challenge_expired':
          return reply
            .code(410)
            .send({ error: 'device_approval_challenge_expired' });
        case 'invalid_device_approval':
          return reply.code(403).send({ error: 'invalid_device_approval' });
        case 'approver_device_not_active':
          return reply
            .code(403)
            .send({ error: 'approver_device_not_active' });
        case 'approver_identity_changed':
          return reply.code(409).send({ error: 'approver_identity_changed' });
        case 'target_device_not_pending':
          return reply.code(409).send({ error: 'target_device_not_pending' });
        case 'target_identity_changed':
          return reply.code(409).send({ error: 'target_identity_changed' });
      }
    },
  );
}
