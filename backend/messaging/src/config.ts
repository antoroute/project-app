const SUPPORTED_ENVIRONMENTS = new Set(['development', 'test', 'staging', 'production']);
const FORBIDDEN_SECRET_VALUES = new Set([
  'dev-secret',
  'changeme',
  'password',
]);

export interface ServiceConfig {
  nodeEnv: string;
  jwtSecret: string;
  appSecret: string;
  databaseUrl: string;
  port: number;
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
  if (value === undefined) return 3001;
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

  const jwtSecret = requiredSecret(env, 'JWT_SECRET');
  const appSecret = requiredSecret(env, 'APP_SECRET');
  if (jwtSecret === appSecret) {
    throw new Error('Invalid configuration: JWT_SECRET and APP_SECRET must be different');
  }

  return Object.freeze({
    nodeEnv,
    jwtSecret,
    appSecret,
    databaseUrl: databaseUrl(env),
    port: port(env),
  });
}
