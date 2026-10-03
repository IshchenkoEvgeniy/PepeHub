import {handlePrivateCover,validCoverAsset,type PrivateCoverBucket} from './covers.ts';
import { validId, validOperation, safeValues, type MetadataSnapshot, type MetadataReceipt } from './metadata.ts';
import { handleActivityApi } from './activity-api.ts';
import { handleNoteApi } from './notes-api.ts';

interface Statement {
  bind(...values: unknown[]): Statement;
  first<T>(): Promise<T | null>;
  all<T>(): Promise<{ results?: T[] }>;
  run(): Promise<unknown>;
}
export interface MetadataDatabase { prepare(sql: string): Statement; batch(statements: Statement[]): Promise<unknown>; }
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
});
const empty: MetadataSnapshot = { version: 1, ready: false, items: [], fields: [], collections: [] };

/** The Companion router authenticates every /api/ route before calling this handler. */
export async function handleMetadataApi(request: Request, db: MetadataDatabase, profile: string, bucket?: PrivateCoverBucket): Promise<Response> {
  const url = new URL(request.url), route = url.pathname.replace('/api/pepehub/library', '');
  if (route.startsWith('/covers/')) return handlePrivateCover(request,profile,bucket);
  if (route === '/notes' || route.startsWith('/notes/')) return handleNoteApi(request, db, profile);
  if (route === '/activity' || route.startsWith('/activity/')) return handleActivityApi(request, db, profile);
  if (request.method === 'GET' && route === '') {
    const row = await db.prepare('SELECT snapshot_json FROM pepehub_library_snapshots WHERE profile_id=?').bind(profile).first<{ snapshot_json: string }>();
    return json(row ? JSON.parse(row.snapshot_json) : empty);
  }
  if (request.method === 'GET' && route === '/pending') {
    const rows = await db.prepare("SELECT operation_json FROM pepehub_library_operations WHERE profile_id=? AND receipt_json IS NULL ORDER BY sequence LIMIT 99")
      .bind(profile).all<{ operation_json: string }>();
    return json({ operations: (rows.results || []).map(row => JSON.parse(row.operation_json)) });
  }
  if (request.method === 'GET' && route.startsWith('/operations/')) {
    const id = route.slice('/operations/'.length);
    if (!validId(id)) return json({ error: 'invalid_id' }, 400);
    const row = await db.prepare('SELECT receipt_json FROM pepehub_library_operations WHERE profile_id=? AND operation_id=?')
      .bind(profile, id).first<{ receipt_json: string | null }>();
    return row ? json(row.receipt_json ? JSON.parse(row.receipt_json) : { operationId: id, status: 'pending' }) : json({ error: 'not_found' }, 404);
  }
  if (request.method !== 'POST') return json({ error: 'not_found' }, 404);
  const limit = route === '/snapshot' ? 1500000 : 128000;
  const declared = Number(request.headers.get('Content-Length'));
  if (declared > limit) return json({ error: 'payload_too_large' }, 413);
  const reader = request.body?.getReader();
  if (!reader) return json({ error: 'invalid_json' }, 400);
  const chunks: Uint8Array[] = []; let length = 0;
  while (true) {
    const chunk = await reader.read(); if (chunk.done) break;
    length += chunk.value.byteLength;
    if (length > limit) { await reader.cancel(); return json({ error: 'payload_too_large' }, 413); }
    chunks.push(chunk.value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let body: unknown;
  try { body = JSON.parse(new TextDecoder().decode(bytes)); } catch { return json({ error: 'invalid_json' }, 400); }
  if (route === '/operations') {
    if (!validOperation(body)) return json({ error: 'invalid_operation' }, 400);
    const operation = JSON.stringify(body);
    await db.prepare('INSERT OR IGNORE INTO pepehub_library_operations(profile_id,operation_id,operation_json) VALUES(?,?,?)')
      .bind(profile, body.operationId, operation).run();
    const row = await db.prepare('SELECT operation_json,receipt_json FROM pepehub_library_operations WHERE profile_id=? AND operation_id=?')
      .bind(profile, body.operationId).first<{ operation_json: string; receipt_json: string | null }>();
    if (!row || row.operation_json !== operation) return json({ error: 'operation_id_reused' }, 409);
    return json(row.receipt_json ? JSON.parse(row.receipt_json) : { operationId: body.operationId, status: 'pending' });
  }
  if (route === '/snapshot') {
    const payload = body as { snapshot?: MetadataSnapshot; receipts?: MetadataReceipt[] };
    const snapshot = payload?.snapshot, receipts = payload?.receipts;
    if (!snapshot || snapshot.version !== 1 || snapshot.ready !== true || !Array.isArray(snapshot.items)
      || !Array.isArray(snapshot.fields) || !Array.isArray(snapshot.collections) || !Array.isArray(receipts)
      || receipts.length > 99 || snapshot.items.some(item => (item.coverAsset != null && !validCoverAsset(item.coverAsset)) || !validId(item.id) || !safeValues(item.values)
        || !Array.isArray(item.fields) || !['book', 'audiobook'].includes(item.mediaType))
      || new Set(snapshot.items.map(item => item.id)).size !== snapshot.items.length
      || receipts.some(receipt => !validId(receipt.operationId) || !['applied', 'conflict', 'error'].includes(receipt.status))) {
      return json({ error: 'invalid_snapshot' }, 400);
    }
    await db.batch([
      db.prepare('INSERT INTO pepehub_library_snapshots(profile_id,snapshot_json) VALUES(?,?) ON CONFLICT(profile_id) DO UPDATE SET snapshot_json=excluded.snapshot_json')
        .bind(profile, JSON.stringify(snapshot)),
      ...receipts.map(receipt => db.prepare('UPDATE pepehub_library_operations SET receipt_json=? WHERE profile_id=? AND operation_id=? AND receipt_json IS NULL')
        .bind(JSON.stringify(receipt), profile, receipt.operationId))
    ]);
    return json({ ok: true });
  }
  return json({ error: 'not_found' }, 404);
}
