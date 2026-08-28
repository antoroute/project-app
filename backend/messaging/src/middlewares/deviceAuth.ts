import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';

import type { DbExecutor } from '../plugins/db.js';
import {
  deviceAccessTranscriptForClaims,
  verifyEd25519Signature,
} from '../security/deviceAccess.js';
import { decodeCanonicalBase64 } from '../security/deviceProof.js';
import { assertAccessClaims, type AccessTokenClaims } from '../security/jwt.js';

export type AccountDeviceState = 'pending' | 'active' | 'revoked';

export interface AuthenticatedAccountDevice {
  deviceId: string;
  identityKeyVersion: number;
  identityPublicKey: Buffer;
  status: AccountDeviceState;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const VERSION_PATTERN = /^[1-9][0-9]{0,9}$/;

export async function authenticateDeviceAccess(
  db: DbExecutor,
  claims: AccessTokenClaims,
  input: {
    deviceId: unknown;
    identityKeyVersion: unknown;
    proof: unknown;
  },
): Promise<AuthenticatedAccountDevice | null> {
  if (
    typeof input.deviceId !== 'string' ||
    !UUID_PATTERN.test(input.deviceId) ||
    typeof input.identityKeyVersion !== 'string' ||
    !VERSION_PATTERN.test(input.identityKeyVersion) ||
    typeof input.proof !== 'string'
  ) {
    return null;
  }
  const identityKeyVersion = Number(input.identityKeyVersion);
  if (
    !Number.isSafeInteger(identityKeyVersion) ||
    identityKeyVersion < 1 ||
    identityKeyVersion > 0xffffffff
  ) {
    return null;
  }

  let signature: Buffer;
  try {
    signature = decodeCanonicalBase64(input.proof, 64);
  } catch {
    return null;
  }

  const row = await db.oneOrNone(
    `SELECT identity_public_key, identity_key_version, status
       FROM account_devices
      WHERE user_id = $1 AND device_id = $2`,
    [claims.sub, input.deviceId],
  );
  if (
    !row ||
    !Buffer.isBuffer(row.identity_public_key) ||
    row.identity_public_key.length !== 32 ||
    Number(row.identity_key_version) !== identityKeyVersion
  ) {
    return null;
  }

  const transcript = deviceAccessTranscriptForClaims(
    claims,
    input.deviceId,
    identityKeyVersion,
  );
  if (
    !verifyEd25519Signature(
      row.identity_public_key as Buffer,
      transcript,
      signature,
    )
  ) {
    return null;
  }

  if (!['pending', 'active', 'revoked'].includes(row.status as string)) {
    return null;
  }
  return {
    deviceId: input.deviceId,
    identityKeyVersion,
    identityPublicKey: row.identity_public_key as Buffer,
    status: row.status as AccountDeviceState,
  };
}

function singleHeader(value: string | string[] | undefined): string | null {
  return typeof value === 'string' ? value : null;
}

export function registerDeviceAuth(app: FastifyInstance): void {
  app.decorateRequest('accountDevice', null);

  app.decorate(
    'identifyDevice',
    async (request: FastifyRequest, reply: FastifyReply) => {
      const claims = assertAccessClaims(request.user);
      const device = await authenticateDeviceAccess(app.db, claims, {
        deviceId: singleHeader(request.headers['x-circlehaven-device-id']),
        identityKeyVersion: singleHeader(
          request.headers['x-circlehaven-device-key-version'],
        ),
        proof: singleHeader(request.headers['x-circlehaven-device-proof']),
      });
      if (!device) {
        await reply
          .code(403)
          .send({ error: 'device_authorization_required' });
        return;
      }
      request.accountDevice = device;
    },
  );

  app.decorate(
    'requireActiveDevice',
    async (request: FastifyRequest, reply: FastifyReply) => {
      await app.identifyDevice(request, reply);
      if (reply.sent) return;
      if (request.accountDevice?.status !== 'active') {
        await reply.code(403).send({
          error:
            request.accountDevice?.status === 'revoked'
              ? 'device_revoked'
              : 'device_not_active',
        });
      }
    },
  );
}

export function authenticatedDevice(request: FastifyRequest) {
  if (!request.accountDevice) throw new Error('Device authentication missing');
  return request.accountDevice;
}
