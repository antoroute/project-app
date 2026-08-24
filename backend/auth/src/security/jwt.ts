import { randomUUID } from 'node:crypto';

import fastifyJwt from '@fastify/jwt';
import type { FastifyInstance } from 'fastify';

export const JWT_ISSUER = 'trust-circle-auth';
export const JWT_ACCESS_AUDIENCE = 'trust-circle-api';
export const JWT_REFRESH_AUDIENCE = 'trust-circle-auth';
export const JWT_TOKEN_VERSION = 1;

const REQUIRED_CLAIMS = ['sub', 'iss', 'aud', 'iat', 'exp', 'jti', 'typ', 'ver'];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface TokenClaims {
  sub: string;
  iss: string;
  aud: string | string[];
  iat: number;
  exp: number;
  jti: string;
  typ: 'access' | 'refresh';
  ver: number;
  nbf?: number;
}

type JwtWithRefresh = FastifyInstance['jwt'] & {
  refresh: FastifyInstance['jwt'];
};

export async function registerJwt(
  app: FastifyInstance,
  accessSecret: string,
  refreshSecret: string,
): Promise<void> {
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

  await app.register(fastifyJwt, {
    secret: refreshSecret,
    namespace: 'refresh',
    sign: {
      algorithm: 'HS256',
      iss: JWT_ISSUER,
      aud: JWT_REFRESH_AUDIENCE,
      header: { alg: 'HS256', typ: 'JWT' },
      expiresIn: '30d',
    },
    verify: {
      algorithms: ['HS256'],
      allowedIss: JWT_ISSUER,
      allowedAud: JWT_REFRESH_AUDIENCE,
      requiredClaims: REQUIRED_CLAIMS,
      checkTyp: 'JWT',
      maxAge: '30d',
      clockTolerance: 0,
    },
  });
}

function assertClaims(payload: unknown, expectedType: TokenClaims['typ']): TokenClaims {
  if (!payload || typeof payload !== 'object') throw new Error('Invalid token claims');
  const claims = payload as Partial<TokenClaims>;
  if (claims.typ !== expectedType || claims.ver !== JWT_TOKEN_VERSION) {
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
  return claims as TokenClaims;
}

export function signAccessToken(app: FastifyInstance, userId: string): string {
  return app.jwt.sign({ sub: userId, jti: randomUUID(), typ: 'access', ver: JWT_TOKEN_VERSION });
}

export function signRefreshToken(app: FastifyInstance, userId: string): string {
  const jwt = app.jwt as JwtWithRefresh;
  return jwt.refresh.sign({ sub: userId, jti: randomUUID(), typ: 'refresh', ver: JWT_TOKEN_VERSION });
}

export function verifyAccessToken(app: FastifyInstance, token: string): TokenClaims {
  return assertClaims(app.jwt.verify(token), 'access');
}

export function verifyRefreshToken(app: FastifyInstance, token: string): TokenClaims {
  const jwt = app.jwt as JwtWithRefresh;
  return assertClaims(jwt.refresh.verify(token), 'refresh');
}

export function assertAccessClaims(payload: unknown): TokenClaims {
  return assertClaims(payload, 'access');
}
