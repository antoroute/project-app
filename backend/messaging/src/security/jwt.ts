import fastifyJwt from '@fastify/jwt';
import type { FastifyInstance } from 'fastify';

export const JWT_ISSUER = 'trust-circle-auth';
export const JWT_ACCESS_AUDIENCE = 'trust-circle-api';
export const JWT_TOKEN_VERSION = 1;

const REQUIRED_CLAIMS = ['sub', 'iss', 'aud', 'iat', 'exp', 'jti', 'typ', 'ver'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface AccessTokenClaims {
  sub: string;
  iss: string;
  aud: string | string[];
  iat: number;
  exp: number;
  jti: string;
  typ: 'access';
  ver: number;
  nbf?: number;
}

export async function registerAccessJwt(app: FastifyInstance, accessSecret: string): Promise<void> {
  await app.register(fastifyJwt, {
    secret: accessSecret,
    sign: {
      algorithm: 'HS256',
      iss: JWT_ISSUER,
      aud: JWT_ACCESS_AUDIENCE,
      header: { alg: 'HS256', typ: 'JWT' },
      expiresIn: '15m',
    },
    verify: {
      algorithms: ['HS256'],
      allowedIss: JWT_ISSUER,
      allowedAud: JWT_ACCESS_AUDIENCE,
      requiredClaims: REQUIRED_CLAIMS,
      checkTyp: 'JWT',
      maxAge: '15m',
      clockTolerance: 0,
    },
  });
}

export function assertAccessClaims(payload: unknown): AccessTokenClaims {
  if (!payload || typeof payload !== 'object') throw new Error('Invalid token claims');
  const claims = payload as Partial<AccessTokenClaims>;
  if (claims.typ !== 'access' || claims.ver !== JWT_TOKEN_VERSION) {
    throw new Error('Invalid token claims');
  }
  if (typeof claims.sub !== 'string' || !UUID_PATTERN.test(claims.sub)) {
    throw new Error('Invalid token claims');
  }
  if (typeof claims.jti !== 'string' || !UUID_PATTERN.test(claims.jti)) {
    throw new Error('Invalid token claims');
  }
  if (!Number.isInteger(claims.iat) || !Number.isInteger(claims.exp) || claims.exp! <= claims.iat!) {
    throw new Error('Invalid token claims');
  }
  if (claims.nbf !== undefined && !Number.isInteger(claims.nbf)) {
    throw new Error('Invalid token claims');
  }
  return claims as AccessTokenClaims;
}

export function verifyAccessToken(app: FastifyInstance, token: string): AccessTokenClaims {
  return assertAccessClaims(app.jwt.verify(token));
}
