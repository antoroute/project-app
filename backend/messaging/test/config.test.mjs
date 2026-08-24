import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { loadConfig } from '../dist/config.js';

const ACCESS_KEYS = generateKeyPairSync('ed25519');
const ACCESS_PUBLIC_KEY_B64 = Buffer.from(
  ACCESS_KEYS.publicKey.export({ type: 'spki', format: 'pem' }),
).toString('base64');

function validEnvironment() {
  return {
    NODE_ENV: 'test',
    JWT_ACCESS_PUBLIC_KEY_B64: ACCESS_PUBLIC_KEY_B64,
    APP_SECRET: 'synthetic-app-secret-material-0000000000000002',
    DATABASE_URL: 'postgresql://test_user:test_password@127.0.0.1:5432/test_db',
    PORT: '4301',
  };
}

test('accepts a complete synthetic configuration', () => {
  const config = loadConfig(validEnvironment());
  assert.equal(config.nodeEnv, 'test');
  assert.equal(config.port, 4301);
});

for (const name of ['NODE_ENV', 'JWT_ACCESS_PUBLIC_KEY_B64', 'APP_SECRET', 'DATABASE_URL']) {
  test(`rejects a missing ${name}`, () => {
    const env = validEnvironment();
    delete env[name];
    assert.throws(() => loadConfig(env), new RegExp(name));
  });
}

test('rejects weak or whitespace-padded values without disclosing them', () => {
  const weak = validEnvironment();
  weak.APP_SECRET = 'dev-secret';
  assert.throws(() => loadConfig(weak), /APP_SECRET/);

  const paddedValue = `${validEnvironment().JWT_ACCESS_PUBLIC_KEY_B64} `;
  const padded = { ...validEnvironment(), JWT_ACCESS_PUBLIC_KEY_B64: paddedValue };
  try {
    loadConfig(padded);
    assert.fail('expected a configuration error');
  } catch (error) {
    assert.doesNotMatch(String(error), new RegExp(paddedValue));
  }
});

test('rejects a non-Ed25519 public key', () => {
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const rsaPublicKey = Buffer.from(
    rsa.publicKey.export({ type: 'spki', format: 'pem' }),
  ).toString('base64');
  assert.throws(
    () => loadConfig({ ...validEnvironment(), JWT_ACCESS_PUBLIC_KEY_B64: rsaPublicKey }),
    /Ed25519 public key/,
  );
});

test('rejects invalid database URLs and ports', () => {
  assert.throws(
    () => loadConfig({ ...validEnvironment(), DATABASE_URL: 'https://example.invalid/db' }),
    /DATABASE_URL/,
  );
  assert.throws(() => loadConfig({ ...validEnvironment(), PORT: '0' }), /PORT/);
  assert.throws(() => loadConfig({ ...validEnvironment(), PORT: '12.5' }), /PORT/);
});

test('the real service process exits before startup when configuration is missing', () => {
  const entrypoint = fileURLToPath(new URL('../dist/index.js', import.meta.url));
  const result = spawnSync(process.execPath, [entrypoint], {
    env: { NODE_ENV: 'test' },
    encoding: 'utf8',
    timeout: 5_000,
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /JWT_ACCESS_PUBLIC_KEY_B64/);
  assert.doesNotMatch(result.stderr, /dev-secret/);
});
