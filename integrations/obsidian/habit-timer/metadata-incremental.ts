import {equalValue, validId, validMetadataFields, validMetadataCollections, validMetadataItem, validMetadataReceipt, type MetadataSnapshot, type MetadataItem, type MetadataReceipt} from './metadata.ts';
import type {MetadataDatabase} from './metadata-api.ts';

const response=(value:unknown,status=200,headers:Record<string,string>={})=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store',...headers}});
interface State {snapshot_json:string;index_id:string|null;cursor:number|null;}
export async function libraryIndex(db:MetadataDatabase,profile:string):Promise<State|null> {
  return db.prepare('SELECT s.snapshot_json,i.index_id,i.cursor FROM pepehub_library_snapshots s LEFT JOIN pepehub_library_index i ON i.profile_id=s.profile_id WHERE s.profile_id=?').bind(profile).first<State>();
}
export async function librarySnapshotResponse(db:MetadataDatabase,profile:string):Promise<Response> {
  const row=await libraryIndex(db,profile);
  const headers:Record<string,string>=row?.index_id?{'X-PepeHub-Index':row.index_id,'X-PepeHub-Cursor':String(row.cursor??0)}:{};
  return response(row?JSON.parse(row.snapshot_json):{version:1,ready:false,items:[],fields:[],collections:[]},200,headers);
}

export async function commitLibrarySnapshot(db:MetadataDatabase,profile:string,snapshot:MetadataSnapshot,receipts:MetadataReceipt[],expected?:{indexId:string;cursor:number}):Promise<Response> {
  const row=await libraryIndex(db,profile);
  if(expected&&(!row||row.index_id!==expected.indexId||row.cursor!==expected.cursor)) return response({error:'stale_index'},409);
  const old:MetadataSnapshot|null=row?JSON.parse(row.snapshot_json):null;
  const indexId=row?.index_id??crypto.randomUUID();
  const before=new Map(old?.items.map(item=>[item.id,item])??[]);
  const after=new Map(snapshot.items.map(item=>[item.id,item]));
  const changed=snapshot.items.filter(item=>!equalValue(before.get(item.id),item));
  const deleted=[...before.keys()].filter(id=>!after.has(id));
  const schema={version:1,ready:true,fields:snapshot.fields,collections:snapshot.collections};
  // Snapshot, journal cursor and receipts describe one transaction. Repeating
  // identical contents adds no journal records and keeps the cursor stable.
  const guard=expected?' AND EXISTS(SELECT 1 FROM pepehub_library_index WHERE profile_id=? AND index_id=? AND cursor=?)':'';
  const args=expected?[profile,expected.indexId,expected.cursor]:[];
  const result=await db.batch([
    db.prepare('INSERT OR IGNORE INTO pepehub_library_index(profile_id,index_id,cursor,schema_json) VALUES(?,?,0,?)').bind(profile,indexId,JSON.stringify(schema)),
    ...changed.map(item=>db.prepare(`INSERT INTO pepehub_library_changes(profile_id,item_id,payload_json) SELECT ?,?,? WHERE 1=1${guard}`).bind(profile,item.id,JSON.stringify(item),...args)),
    ...deleted.map(id=>db.prepare(`INSERT INTO pepehub_library_changes(profile_id,item_id,payload_json) SELECT ?,?,NULL WHERE 1=1${guard}`).bind(profile,id,...args)),
    db.prepare(`INSERT INTO pepehub_library_snapshots(profile_id,snapshot_json) SELECT ?,? WHERE 1=1${guard} ON CONFLICT(profile_id) DO UPDATE SET snapshot_json=excluded.snapshot_json`).bind(profile,JSON.stringify(snapshot),...args),
    ...receipts.map(receipt=>db.prepare(`UPDATE pepehub_library_operations SET receipt_json=? WHERE profile_id=? AND operation_id=? AND receipt_json IS NULL${guard}`).bind(JSON.stringify(receipt),profile,receipt.operationId,...args)),
    db.prepare(`UPDATE pepehub_library_index SET schema_json=?,cursor=(SELECT COALESCE(MAX(sequence),0) FROM pepehub_library_changes WHERE profile_id=?) WHERE profile_id=?${guard} RETURNING index_id,cursor`).bind(JSON.stringify(schema),profile,profile,...args),
  ]) as Array<{results?:Array<{index_id:string;cursor:number}>}>;
  const committed=result.at(-1)?.results?.[0];
  if(!committed) return response({error:'stale_index'},409);
  return response({ok:true,indexId:committed.index_id,cursor:committed.cursor});
}

export async function libraryChanges(request:Request,db:MetadataDatabase,profile:string):Promise<Response> {
  const url=new URL(request.url),indexId=url.searchParams.get('index'),after=Number(url.searchParams.get('after'));
  if(!validId(indexId)||!Number.isSafeInteger(after)||after<0) return response({error:'invalid_cursor'},400);
  const state=await db.prepare('SELECT index_id,cursor,schema_json FROM pepehub_library_index WHERE profile_id=?').bind(profile).first<{index_id:string;cursor:number;schema_json:string}>();
  if(!state||state.index_id!==indexId||after>state.cursor) return response({reset:true},409);
  const rows=await db.prepare('SELECT sequence,item_id,payload_json FROM pepehub_library_changes WHERE profile_id=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT 129').bind(profile,after,state.cursor).all<{sequence:number;item_id:string;payload_json:string|null}>();
  const page=(rows.results??[]).slice(0,128),next=page.at(-1)?.sequence??state.cursor;
  return response({version:1,indexId,cursor:next,hasMore:(rows.results?.length??0)>128,changes:page.map(r=>({id:r.item_id,item:r.payload_json===null?null:JSON.parse(r.payload_json)})),schema:JSON.parse(state.schema_json)});
}

export async function publishLibraryDelta(body:unknown,db:MetadataDatabase,profile:string):Promise<Response> {
  const p=body as {version?:number;indexId?:string;cursor?:number;changes?:Array<{id:string;item:MetadataItem|null}>;fields?:MetadataSnapshot['fields'];collections?:MetadataSnapshot['collections'];receipts?:MetadataReceipt[]};
  if(p?.version!==1||!validId(p.indexId)||!Number.isSafeInteger(p.cursor)||(p.cursor??-1)<0||!Array.isArray(p.changes)||p.changes.length>128||!Array.isArray(p.receipts)||p.receipts.length>99||
    p.changes.some(c=>!c||!validId(c.id)||(c.item!==null&&(!validMetadataItem(c.item)||c.item.id!==c.id)))||
    new Set(p.changes.map(c=>c.id)).size!==p.changes.length||p.receipts.some(r=>!validMetadataReceipt(r))) return response({error:'invalid_delta'},400);
  const row=await libraryIndex(db,profile);
  if(!row||row.index_id!==p.indexId||row.cursor!==p.cursor) return response({error:'stale_index'},409);
  const snapshot=JSON.parse(row.snapshot_json) as MetadataSnapshot;
  const items=new Map(snapshot.items.map(item=>[item.id,item]));
  for(const change of p.changes) { if(change.item===null)items.delete(change.id);else items.set(change.id,change.item); }
  if(p.fields!==undefined&&!validMetadataFields(p.fields)||p.collections!==undefined&&!validMetadataCollections(p.collections)) return response({error:'invalid_schema'},400);
  return commitLibrarySnapshot(db,profile,{...snapshot,items:[...items.values()],fields:p.fields??snapshot.fields,collections:p.collections??snapshot.collections},p.receipts,{indexId:p.indexId,cursor:p.cursor!});
}
