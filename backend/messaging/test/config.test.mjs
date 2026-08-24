import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { loadConfig } from '../dist/config.js';

function validEnvironment() {
  return {
    NODE_ENV: 'test',
    JWT_ACCESS_SECRET: 'synthetic-access-secret-material-00000000000001',
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

for (const name of ['NODE_ENV', 'JWT_ACCESS_SECRET', 'APP_SECRET', 'DATABASE_URL']) {
  test(`rejects a missing ${name}`, () => {
    const env = validEnvironment();
    delete env[name];
    assert.throws(() => loadConfig(env), new RegExp(name));
  });
}

test('rejects weak, reused or whitespace-padded secrets without disclosing them', () => {
  const weak = validEnvironment();
  weak.JWT_ACCESS_SECRET = 'dev-secret';
  assert.throws(() => loadConfig(weak), /JWT_ACCESS_SECRET/);

  const reused = validEnvironment();
  reused.APP_SECRET = reused.JWT_ACCESS_SECRET;
  assert.throws(() => loadConfig(reused), /must be different/);

  const paddedValue = `${validEnvironment().JWT_ACCESS_SECRET} `;
  const padded = { ...validEnvironment(), JWT_ACCESS_SECRET: paddedValue };
  try {
    loadConfig(padded);
    assert.fail('expected a configuration error');
  } catch (error) {
    assert.doesNotMatch(String(error), new RegExp(paddedValue));
  }
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
  assert.match(result.stderr, /JWT_ACCESS_SECRET/);
  assert.doesNotMatch(result.stderr, /dev-secret/);
});
