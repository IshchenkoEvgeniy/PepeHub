import type { ChangePage, Entity, Operation, Receipt } from '../../../contracts/protocol.ts';
import type { Database } from './database.ts';

const entityJson = `json_object('entityType',entity_type,'entityId',entity_id,'revision',revision,'deleted',json(CASE WHEN deleted=1 THEN 'true' ELSE 'false' END),'payload',json(payload_json))`;
export class ReusedOperationError extends Error {}

export async function applyOperation(db: Database, owner: string, op: Operation): Promise<Receipt> {
  const request = JSON.stringify(op);
  const existing = () => db.prepare('SELECT request_json, result_json FROM operations WHERE owner_id=? AND operation_id=?').bind(owner,op.operationId).first<{request_json:string;result_json:string}>();
  const decode = (row: {request_json:string;result_json:string}): Receipt => {
    if (row.request_json !== request) throw new ReusedOperationError('Operation ID already used with different content');
    return JSON.parse(row.result_json) as Receipt;
  };
  const previous = await existing();
  if (previous) return decode(previous);
  const key = [owner,op.entityType,op.entityId];
  // No read-then-write decision: revision comparison happens inside the SQL transaction.
  // A stale put, missing parent or tombstone yields a durable conflict receipt.
  const parentCondition = op.entityType === 'session' && op.action === 'put'
    ? ` AND EXISTS(SELECT 1 FROM entities WHERE owner_id=? AND entity_type='book' AND entity_id=? AND deleted=0)` : '';
  const parentArgs = parentCondition ? [owner,(op.payload as {bookId:string}).bookId] : [];
  try {
    await db.batch([
      db.prepare('INSERT INTO operations(owner_id,operation_id,device_id,request_json) VALUES(?,?,?,?)').bind(owner,op.operationId,op.deviceId,request),
      db.prepare(`INSERT INTO entities(owner_id,entity_type,entity_id,revision,deleted,payload_json,last_operation_id)
        SELECT ?,?,?,1,?,?,? WHERE (?=0 OR EXISTS(SELECT 1 FROM entities WHERE owner_id=? AND entity_type=? AND entity_id=?)) ${parentCondition}
        ON CONFLICT(owner_id,entity_type,entity_id) DO UPDATE SET revision=entities.revision+1,deleted=excluded.deleted,payload_json=excluded.payload_json,last_operation_id=excluded.last_operation_id
        WHERE entities.revision=? AND entities.deleted=0`)
        .bind(...key,op.action === 'delete' ? 1 : 0,JSON.stringify(op.payload),op.operationId,op.baseRevision,...key,...parentArgs,op.baseRevision),
      db.prepare(`INSERT INTO change_log(owner_id,operation_id,entity_json) SELECT owner_id,last_operation_id,${entityJson} FROM entities WHERE owner_id=? AND entity_type=? AND entity_id=? AND last_operation_id=?`).bind(...key,op.operationId),
      db.prepare(`UPDATE operations SET result_json=json_object('operationId',operation_id,'status',CASE WHEN EXISTS(SELECT 1 FROM entities WHERE owner_id=? AND entity_type=? AND entity_id=? AND last_operation_id=?) THEN 'accepted' ELSE 'conflict' END,'current',json((SELECT ${entityJson} FROM entities WHERE owner_id=? AND entity_type=? AND entity_id=?))) WHERE owner_id=? AND operation_id=?`)
        .bind(...key,op.operationId,...key,owner,op.operationId),
    ]);
  } catch (error) {
    // Another request can win the unique operation ID while this batch is waiting.
    const duplicate = await existing();
    if (duplicate?.result_json) return decode(duplicate);
    throw error;
  }
  const result = await existing();
  if (!result?.result_json) throw new Error('Missing transaction receipt');
  return decode(result);
}

export async function getChanges(db: Database, owner: string, after: number, limit: number): Promise<ChangePage> {
  const rows = await db.prepare('SELECT sequence,operation_id,entity_json FROM change_log WHERE owner_id=? AND sequence>? ORDER BY sequence LIMIT ?').bind(owner,after,limit+1).all<{sequence:number;operation_id:string;entity_json:string}>();
  const page = rows.results.slice(0,limit);
  return { schemaVersion: 1, changes: page.map(r => ({...JSON.parse(r.entity_json) as Entity,sequence:r.sequence,operationId:r.operation_id})), cursor:page.at(-1)?.sequence ?? after,hasMore:rows.results.length>limit };
}
