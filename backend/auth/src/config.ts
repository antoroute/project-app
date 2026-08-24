import { createPrivateKey, createPublicKey } from 'node:crypto';

const SUPPORTED_ENVIRONMENTS = new Set(['development', 'test', 'staging', 'production']);
const FORBIDDEN_SECRET_VALUES = new Set([
  'dev-secret',
  'changeme',
  'password',
]);

export interface ServiceConfig {
  nodeEnv: string;
  jwtAccessPrivateKey: string;
  jwtAccessPublicKey: string;
  jwtRefreshSecret: string;
  appSecret: string;
  databaseUrl: string;
  port: number;
}

function requiredBase64(env: NodeJS.ProcessEnv, name: string): Buffer {
  const value = requiredValue(env, name);
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    throw new Error(`Invalid configuration: ${name} must be canonical base64`);
  }
  const decoded = Buffer.from(value, 'base64');
  if (decoded.toString('base64') !== value) {
    throw new Error(`Invalid configuration: ${name} must be canonical base64`);
  }
  return decoded;
}

function accessKeyPair(env: NodeJS.ProcessEnv): { privateKey: string; publicKey: string } {
  const privateKeyValue = requiredBase64(env, 'JWT_ACCESS_PRIVATE_KEY_B64').toString('utf8');
  const publicKeyValue = requiredBase64(env, 'JWT_ACCESS_PUBLIC_KEY_B64').toString('utf8');
  try {
    const privateKey = createPrivateKey(privateKeyValue);
    const publicKey = createPublicKey(publicKeyValue);
    const derivedPublicKey = createPublicKey(privateKey);
    if (privateKey.asymmetricKeyType !== 'ed25519' || publicKey.asymmetricKeyType !== 'ed25519') {
      throw new Error('wrong key type');
    }
    const configuredDer = publicKey.export({ type: 'spki', format: 'der' });
    const derivedDer = derivedPublicKey.export({ type: 'spki', format: 'der' });
    if (!configuredDer.equals(derivedDer)) throw new Error('key pair mismatch');
  } catch {
    throw new Error('Invalid configuration: JWT access keys must be a matching Ed25519 pair');
  }
  return { privateKey: privateKeyValue, publicKey: publicKeyValue };
}

function requiredValue(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`Invalid configuration: ${name} is required`);
  }
  if (value !== value.trim()) {
    throw new Error(`Invalid configuration: ${name} must not contain surrounding whitespace`);
  }
  return value;
}

function requiredSecret(env: NodeJS.ProcessEnv, name: string): string {
  const value = requiredValue(env, name);
  if (value.length < 32) {
    throw new Error(`Invalid configuration: ${name} must contain at least 32 characters`);
  }
  if (FORBIDDEN_SECRET_VALUES.has(value.toLowerCase()) || value.toLowerCase().startsWith('kavalek_app_')) {
    throw new Error(`Invalid configuration: ${name} uses a forbidden placeholder`);
  }
  return value;
}

function databaseUrl(env: NodeJS.ProcessEnv): string {
  const value = requiredValue(env, 'DATABASE_URL');
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error('Invalid configuration: DATABASE_URL must be a valid PostgreSQL URL');
  }

  if (!['postgres:', 'postgresql:'].includes(parsed.protocol)) {
    throw new Error('Invalid configuration: DATABASE_URL must use postgres or postgresql');
  }
  if (!parsed.hostname || !parsed.username || !parsed.password || parsed.pathname === '/') {
    throw new Error('Invalid configuration: DATABASE_URL must include host, database and credentials');
  }
  return value;
}

function port(env: NodeJS.ProcessEnv): number {
  const value = env.PORT;
  if (value === undefined) return 3000;
  if (!/^[0-9]+$/.test(value)) {
    throw new Error('Invalid configuration: PORT must be an integer between 1 and 65535');
  }
  const parsed = Number(value);
  if (parsed < 1 || parsed > 65535) {
    throw new Error('Invalid configuration: PORT must be an integer between 1 and 65535');
  }
  return parsed;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Readonly<ServiceConfig> {
  const nodeEnv = requiredValue(env, 'NODE_ENV');
  if (!SUPPORTED_ENVIRONMENTS.has(nodeEnv)) {
    throw new Error('Invalid configuration: NODE_ENV is not supported');
  }

  const accessKeys = accessKeyPair(env);
  const jwtRefreshSecret = requiredSecret(env, 'JWT_REFRESH_SECRET');
  const appSecret = requiredSecret(env, 'APP_SECRET');
  if (jwtRefreshSecret === appSecret) {
    throw new Error('Invalid configuration: JWT_REFRESH_SECRET and APP_SECRET must be different');
  }

  return Object.freeze({
    nodeEnv,
    jwtAccessPrivateKey: accessKeys.privateKey,
    jwtAccessPublicKey: accessKeys.publicKey,
    jwtRefreshSecret,
    appSecret,
    databaseUrl: databaseUrl(env),
    port: port(env),
  });
}
