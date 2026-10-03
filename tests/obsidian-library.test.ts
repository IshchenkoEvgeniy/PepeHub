import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { SqliteDatabase } from '../scripts/sqlite-adapter.ts';
import { handleMetadataApi } from '../integrations/obsidian/habit-timer/metadata-api.ts';
import { conflictingKeys, validOperation, equalValue, type MetadataOperation, type MetadataSnapshot } from '../integrations/obsidian/habit-timer/metadata.ts';

function setup() {
  const db = new SqliteDatabase();
  db.sqlite.exec(readFileSync(new URL('../integrations/obsidian/habit-timer/001_pepehub_library.sql', import.meta.url), 'utf8'));
  const call = (path = '', body?: unknown, profile = 'one') => handleMetadataApi(new Request(`https://example.test/api/pepehub/library${path}`,
    body === undefined ? {} : { method: 'POST', body: JSON.stringify(body) }), db, profile);
  return { db, call };
}
const operation = (): MetadataOperation => ({ operationId: randomUUID(), itemId: randomUUID(), action: 'create',
  collectionId: 'book', mediaType: 'book', base: {}, values: { Title: 'Одинаковое название', 'End Date': null } });
const snapshot = (): MetadataSnapshot => ({ version: 1, ready: true, fields: [{ key: 'End Date', field: 'endDate', kind: 'text' }],
  collections: [{ id: 'book', mediaType: 'book', title: 'Books' }], items: Array.from({ length: 120 }, () => ({
    id: randomUUID(), path: 'Books/Book.md', collectionId: 'book', mediaType: 'book', modifiedAt: 0,
    values: { Title: 'Same', 'End Date': null, Custom: { tags: ['one', 'two'], flag: false } }, fields: [] })) });

test('full 120-card snapshots, empty values, custom properties and isolated profiles', async () => {
  const { db, call } = setup();
  try {
    assert.equal((await (await call()).json()).ready, false);
    const data = snapshot();
    assert.equal((await call('/snapshot', { snapshot: data, receipts: [] })).status, 200);
    assert.deepEqual(await (await call()).json(), data);
    assert.equal((await (await call('', undefined, 'two')).json()).ready, false);
    assert.equal((await (await call('/pending')).json()).operations.length, 0);
    assert.equal((await call('/snapshot', { snapshot: { ...data, items: [data.items[0], data.items[0]] }, receipts: [] })).status, 400);
  } finally { db.close(); }
});

test('manual add is durable and idempotent; snapshot and acknowledgement commit together', async () => {
  const { db, call } = setup();
  try {
    const op = operation();
    const responses = await Promise.all(Array.from({ length: 8 }, () => call('/operations', op)));
    assert.ok(responses.every(response => response.status === 200));
    assert.equal((await (await call('/pending')).json()).operations.length, 1);
    assert.equal((await call('/operations', { ...op, values: { Title: 'Changed' } })).status, 409);
    const receipt = { operationId: op.operationId, status: 'applied' };
    await call('/snapshot', { snapshot: snapshot(), receipts: [receipt] });
    assert.deepEqual(await (await call(`/operations/${op.operationId}`)).json(), receipt);
    assert.deepEqual(await (await call('/operations', op)).json(), receipt);
    assert.equal((await (await call('/pending')).json()).operations.length, 0);
    assert.equal((await call(`/operations/${op.operationId}`, undefined, 'two')).status, 404);
    const another = operation();
    await call('/operations', another);
    assert.notEqual(another.itemId, op.itemId);
  } finally { db.close(); }
});

test('lost responses and conflicting fields keep stable receipts; malformed payloads are rejected', async () => {
  const { db, call } = setup();
  try {
    const op = operation(); await call('/operations', op);
    const receipt = { operationId: op.operationId, status: 'conflict', message: 'Edited in Obsidian' };
    await call('/snapshot', { snapshot: snapshot(), receipts: [receipt] });
    await call('/snapshot', { snapshot: snapshot(), receipts: [{ operationId: op.operationId, status: 'applied' }] });
    assert.deepEqual(await (await call(`/operations/${op.operationId}`)).json(), receipt);
    assert.equal((await call('/operations', { ...op, itemId: 'name-only' })).status, 400);
    assert.equal(validOperation({ ...op, values: JSON.parse('{"__proto__":{"polluted":true}}') }), false);
    assert.equal((await call('/operations', { ...operation(), values: { notes: 'x'.repeat(128001) } })).status, 413);
  } finally { db.close(); }
});

test('field merge preserves unrelated changes, detects concurrent edits, and accepts a replay', () => {
  const op = { ...operation(), action: 'update' as const, base: { Rating: '7', 'End Date': null }, values: { Rating: '9', 'End Date': '2026-10-03' } };
  assert.deepEqual(conflictingKeys({ Rating: '7', Notes: 'Written in Obsidian' }, op), []);
  assert.deepEqual(conflictingKeys({ Rating: '8', 'End Date': null }, op), ['Rating']);
  assert.deepEqual(conflictingKeys({ Rating: '9', 'End Date': '2026-10-03' }, op), []);
  assert.equal(equalValue({ b: [1, null], a: 2 }, { a: 2, b: [1, null] }), true);
});
