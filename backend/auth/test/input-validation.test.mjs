import assert from 'node:assert/strict';
import test from 'node:test';

import Fastify from 'fastify';

import authRoutes from '../dist/routes/auth.js';

async function validationApp() {
  const calls = [];
  const app = Fastify({
    logger: false,
    bodyLimit: 16 * 1024,
    ajv: { customOptions: { removeAdditional: false } },
  });
  app.decorate('authenticate', async () => undefined);
  app.decorate('db', {
    one: async (...args) => {
      calls.push(args);
      throw new Error('database must not be reached');
    },
    any: async () => [],
    none: async () => undefined,
  });
  await app.register(authRoutes);
  await app.ready();
  return { app, calls };
}

test('refuse les champs inconnus et les identifiants hors limites avant la base', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());

  const payloads = [
    { email: 'alice@example.test', username: 'Alice', password: 'password-secure', admin: true },
    { email: `${'a'.repeat(243)}@example.test`, username: 'Alice', password: 'password-secure' },
    { email: 'alice@example.test', username: ' Alice', password: 'password-secure' },
    { email: 'alice@example.test', username: 'Ali\u0000ce', password: 'password-secure' },
    { email: 'alice@example.test', username: 'a'.repeat(65), password: 'password-secure' },
    { email: 'alice@example.test', username: 'Alice', password: 'p'.repeat(1025) },
  ];

  for (const payload of payloads) {
    const response = await app.inject({ method: 'POST', url: '/register', payload });
    assert.equal(response.statusCode, 400);
  }
  assert.equal(calls.length, 0);
});

test('refuse un login inconnu ou hors limites avant la base', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());

  for (const payload of [
    { email: 'alice@example.test', password: 'password-secure', unexpected: true },
    { email: 'alice@example.test', password: 'short' },
    { email: 'alice@example.test', password: 'p'.repeat(1025) },
  ]) {
    const response = await app.inject({ method: 'POST', url: '/login', payload });
    assert.equal(response.statusCode, 400);
  }
  assert.equal(calls.length, 0);
});

test('borne le corps HTTP auth à 16 Kio', async (t) => {
  const { app, calls } = await validationApp();
  t.after(() => app.close());

  const response = await app.inject({
    method: 'POST',
    url: '/register',
    headers: { 'content-type': 'application/json' },
    payload: JSON.stringify({
      email: 'alice@example.test',
      username: 'Alice',
      password: 'p'.repeat(17 * 1024),
    }),
  });

  assert.equal(response.statusCode, 413);
  assert.equal(calls.length, 0);
});
