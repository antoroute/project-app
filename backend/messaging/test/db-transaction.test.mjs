import assert from 'node:assert/strict';
import test from 'node:test';

import { runInTransaction } from '../dist/plugins/db.js';

function fakePool(queryHandler = async () => ({ rows: [] })) {
  const queries = [];
  let releases = 0;
  const pool = {
    async connect() {
      return {
        async query(query, params) {
          queries.push({ query, params });
          return queryHandler(query, params, queries);
        },
        release() {
          releases += 1;
        },
      };
    },
  };
  return { pool, queries, releases: () => releases };
}

test('la transaction commit sur le même client puis le libère', async () => {
  const fixture = fakePool(async (query) => ({
    rows: query === 'SELECT value' ? [{ value: 42 }] : [],
  }));

  const result = await runInTransaction(fixture.pool, async (tx) => {
    const row = await tx.one('SELECT value');
    await tx.none('UPDATE synthetic SET value=$1', [row.value]);
    return row.value;
  });

  assert.equal(result, 42);
  assert.deepEqual(fixture.queries.map(({ query }) => query), [
    'BEGIN ISOLATION LEVEL READ COMMITTED',
    'SELECT value',
    'UPDATE synthetic SET value=$1',
    'COMMIT',
  ]);
  assert.equal(fixture.releases(), 1);
});

test('une erreur métier rollback sans commit et libère le client', async () => {
  const fixture = fakePool();
  const failure = new Error('synthetic failure');

  await assert.rejects(
    runInTransaction(fixture.pool, async (tx) => {
      await tx.none('INSERT synthetic');
      throw failure;
    }),
    failure,
  );

  assert.deepEqual(fixture.queries.map(({ query }) => query), [
    'BEGIN ISOLATION LEVEL READ COMMITTED',
    'INSERT synthetic',
    'ROLLBACK',
  ]);
  assert.equal(fixture.releases(), 1);
});

test('une sérialisation échouée est rejouée dans la limite demandée', async () => {
  let businessAttempts = 0;
  const fixture = fakePool();

  const result = await runInTransaction(
    fixture.pool,
    async () => {
      businessAttempts += 1;
      if (businessAttempts === 1) {
        throw Object.assign(new Error('serialization failure'), { code: '40001' });
      }
      return 'ok';
    },
    { isolationLevel: 'SERIALIZABLE', maxRetries: 1 },
  );

  assert.equal(result, 'ok');
  assert.equal(businessAttempts, 2);
  assert.equal(fixture.releases(), 2);
  assert.deepEqual(fixture.queries.map(({ query }) => query), [
    'BEGIN ISOLATION LEVEL SERIALIZABLE',
    'ROLLBACK',
    'BEGIN ISOLATION LEVEL SERIALIZABLE',
    'COMMIT',
  ]);
});

test('une erreur non transitoire ne déclenche aucun retry', async () => {
  let attempts = 0;
  const fixture = fakePool();

  await assert.rejects(runInTransaction(fixture.pool, async () => {
    attempts += 1;
    throw Object.assign(new Error('constraint failure'), { code: '23505' });
  }));

  assert.equal(attempts, 1);
  assert.equal(fixture.releases(), 1);
});

test('les retries transitoires restent strictement bornés', async () => {
  let attempts = 0;
  const fixture = fakePool();

  await assert.rejects(runInTransaction(
    fixture.pool,
    async () => {
      attempts += 1;
      throw Object.assign(new Error('deadlock'), { code: '40P01' });
    },
    { maxRetries: 1 },
  ));

  assert.equal(attempts, 2);
  assert.equal(fixture.releases(), 2);
});
