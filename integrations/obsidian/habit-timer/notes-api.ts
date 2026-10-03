import { validNoteOperation, type NoteOperation } from './notes.ts';
import type { MetadataDatabase } from './metadata-api.ts';
const json = (v: unknown, status = 200) => new Response(JSON.stringify(v), {status, headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
type Row = { sequence: number; revision: number; entry_json: string };
const record = (row: Row) => ({entry: JSON.parse(row.entry_json), revision: row.revision, sequence: row.sequence});

/** Called only after Companion authentication; every query is profile scoped. */
export async function handleNoteApi(request: Request, db: MetadataDatabase, profile: string): Promise<Response> {
  const url = new URL(request.url);
  const route = url.pathname.slice('/api/pepehub/library/notes'.length);
  if (request.method === 'GET' && route === '') {
    const after = Number(url.searchParams.get('after') || 0);
    if (!Number.isSafeInteger(after) || after < 0) return json({error:'invalid_cursor'},400);
    const rows = (await db.prepare('SELECT sequence,revision,entry_json FROM pepehub_notes_changes WHERE profile_id=? AND sequence>? ORDER BY sequence LIMIT 21').bind(profile,after).all<Row>()).results || [];
    const page:Row[]=[];let bytes=0;
    for(const row of rows.slice(0,20)){const size=new TextEncoder().encode(row.entry_json).length;if(page.length&&bytes+size>1300000)break;page.push(row);bytes+=size;}
    return json({version:1, records:page.map(record), cursor:page.at(-1)?.sequence ?? after, hasMore:rows.length > page.length});
  }
  if (request.method !== 'POST' || route !== '') return json({error:'not_found'},404);
  const reader = request.body?.getReader(); if (!reader) return json({error:'invalid_json'},400);
  const chunks: Uint8Array[] = []; let size = 0;
  while (true) { const chunk = await reader.read(); if (chunk.done) break; size += chunk.value.byteLength; if (size > 1500000) {await reader.cancel(); return json({error:'payload_too_large'},413);} chunks.push(chunk.value); }
  const bytes = new Uint8Array(size); let offset=0; for (const chunk of chunks) {bytes.set(chunk,offset); offset+=chunk.length;}
  let body: {operations?: NoteOperation[]};
  try {body=JSON.parse(new TextDecoder().decode(bytes));} catch {return json({error:'invalid_json'},400);}
  if (!body || !Array.isArray(body.operations) || body.operations.length > 2 || body.operations.some(op => !validNoteOperation(op))) return json({error:'invalid_notes'},400);
  const snapshot = await db.prepare('SELECT snapshot_json FROM pepehub_library_snapshots WHERE profile_id=?').bind(profile).first<{snapshot_json:string}>();
  const items = new Map<string,string>((snapshot ? JSON.parse(snapshot.snapshot_json).items : []).map((i:{id:string;mediaType:string})=>[i.id,i.mediaType]));
  if (body.operations.some(op => items.get(op.entry.itemId) !== op.entry.mediaType)) return json({error:'unknown_library_item'},409);
  const receipts: unknown[]=[];
  for (const op of body.operations) {
    const existing=await db.prepare('SELECT entry_json FROM pepehub_notes_changes WHERE profile_id=? AND entry_id=? ORDER BY revision DESC LIMIT 1').bind(profile,op.entry.id).first<{entry_json:string}>();
    if(existing && JSON.parse(existing.entry_json).itemId!==op.entry.itemId)return json({error:'entry_identity_changed'},409);
    const encoded = JSON.stringify(op);
    // The transaction records the immutable request, performs CAS, then persists its receipt.
    // Retries return that receipt even when a later edit has superseded this revision.
    await db.batch([
      db.prepare('INSERT OR IGNORE INTO pepehub_notes_operations(profile_id,operation_id,operation_json) VALUES(?,?,?)').bind(profile,op.operationId,encoded),
      db.prepare(`INSERT OR IGNORE INTO pepehub_notes_changes(profile_id,entry_id,revision,entry_json,operation_id)
        SELECT ?,?,?,?,? WHERE COALESCE((SELECT MAX(revision) FROM pepehub_notes_changes WHERE profile_id=? AND entry_id=?),0)=?
        AND EXISTS(SELECT 1 FROM pepehub_notes_operations WHERE profile_id=? AND operation_id=? AND operation_json=? AND receipt_json IS NULL)`)
        .bind(profile,op.entry.id,op.baseRevision+1,JSON.stringify(op.entry),op.operationId,profile,op.entry.id,op.baseRevision,profile,op.operationId,encoded),
      db.prepare(`UPDATE pepehub_notes_operations SET receipt_json=json_object('operationId',operation_id,
        'status',CASE WHEN EXISTS(SELECT 1 FROM pepehub_notes_changes WHERE profile_id=? AND operation_id=?) THEN 'applied' ELSE 'conflict' END,
        'record',json((SELECT json_object('entry',json(entry_json),'revision',revision,'sequence',sequence) FROM pepehub_notes_changes WHERE profile_id=? AND entry_id=? ORDER BY revision DESC LIMIT 1)))
        WHERE profile_id=? AND operation_id=? AND operation_json=? AND receipt_json IS NULL`)
        .bind(profile,op.operationId,profile,op.entry.id,profile,op.operationId,encoded),
    ]);
    const saved = await db.prepare('SELECT operation_json,receipt_json FROM pepehub_notes_operations WHERE profile_id=? AND operation_id=?').bind(profile,op.operationId).first<{operation_json:string;receipt_json:string}>();
    if (saved?.operation_json !== encoded) return json({error:'operation_id_reused'},409);
    receipts.push(JSON.parse(saved.receipt_json));
  }
  return json({version:1,receipts});
}
