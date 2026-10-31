import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {SqliteDatabase} from '../scripts/sqlite-adapter.ts';
import worker,{hashToken} from '../services/sync-worker/src/index.ts';
import {applyOperation,getChanges} from '../services/sync-worker/src/store.ts';
import {bookFormats,parseOperation,type Operation,type Book} from '../contracts/protocol.ts';
const owner=randomUUID(),device=randomUUID();
const book=(overrides:Partial<Operation>={}):Operation=>({schemaVersion:1,operationId:randomUUID(),deviceId:device,entityType:'book',entityId:randomUUID(),baseRevision:0,action:'put',payload:{title:'Тестовая книга',authors:['Автор'],format:'epub',status:'planned'},...overrides});

test('all supported book formats survive validation and the server change log',async()=>{
  const db=new SqliteDatabase();
  try {
    for(const format of bookFormats) {
      const op=parseOperation(book({payload:{title:'Книга',authors:[],format,status:'planned'}}));
      assert.equal((await applyOperation(db,owner,op)).status,'accepted');
    }
    assert.deepEqual((await getChanges(db,owner,0,100)).changes.map(c=>(c.payload as Book).format), [...bookFormats]);
    assert.throws(()=>parseOperation(book({payload:{title:'Unknown',authors:[],format:'exe' as Book['format'],status:'planned'}})));
  } finally {db.close();}
});

test('paused and abandoned books retain their status through validation and the change log',async()=>{
  const db=new SqliteDatabase();
  try {
    for (const status of ['paused','abandoned'] as const) {
      const op=parseOperation(book({payload:{title:'Книга',authors:[],format:'epub',status}}));
      assert.equal((await applyOperation(db,owner,op)).status,'accepted');
    }
    assert.deepEqual((await getChanges(db,owner,0,100)).changes.map(c=>(c.payload as Book).status),['paused','abandoned']);
  } finally { db.close(); }
});

test('lost response and concurrent retries produce one entity revision and one log entry',async()=>{
  const db=new SqliteDatabase();try {
    const op=book(); const receipts=await Promise.all(Array.from({length:8},()=>applyOperation(db,owner,op)));
    receipts.forEach(r=>assert.deepEqual(r,receipts[0]));
    assert.equal(receipts[0].status,'accepted');assert.equal(receipts[0].current?.revision,1);
    assert.equal((await getChanges(db,owner,0,100)).changes.length,1);
    await assert.rejects(()=>applyOperation(db,owner,{...op,action:'delete',payload:null}));
  } finally {db.close();}
});
test('stale edits conflict, conflict receipt stays stable, tombstones reject resurrection',async()=>{
  const db=new SqliteDatabase();try {
    const original=book(); await applyOperation(db,owner,original);
    const edit=book({entityId:original.entityId,baseRevision:1});
    const stale=book({entityId:original.entityId,baseRevision:1});
    assert.equal((await applyOperation(db,owner,edit)).status,'accepted');
    const receipt=await applyOperation(db,owner,stale);
    assert.equal(receipt.status,'conflict');assert.equal(receipt.current?.revision,2);
    await applyOperation(db,owner,book({entityId:original.entityId,baseRevision:2,action:'delete',payload:null}));
    assert.deepEqual(await applyOperation(db,owner,stale),receipt);
    const resurrection=await applyOperation(db,owner,book({entityId:original.entityId,baseRevision:3}));
    assert.equal(resurrection.status,'conflict');assert.equal(resurrection.current?.deleted,true);
    assert.equal((await getChanges(db,owner,0,100)).changes.length,3);
  } finally {db.close();}
});
test('independent sessions merge; unknown or another owner book cannot receive sessions',async()=>{
  const db=new SqliteDatabase();try {
    const b=book();await applyOperation(db,owner,b);
    const session=():Operation=>book({entityType:'session',payload:{bookId:b.entityId,kind:'reading',startedAt:'2026-09-11T10:00:00Z',endedAt:'2026-09-11T10:20:00Z',activeSeconds:1200,timezone:'Europe/Kyiv',source:'manual'}});
    for(let i=0;i<2;i++) assert.equal((await applyOperation(db,owner,parseOperation(session()))).status,'accepted');
    assert.equal((await applyOperation(db,'other-owner',session())).status,'conflict');
    assert.equal((await getChanges(db,owner,0,100)).changes.length,3);
  } finally {db.close();}
});
test('player timezone offsets roundtrip without weakening session input validation',async()=>{
  const db=new SqliteDatabase();try {
    const b=book();await applyOperation(db,owner,b);
    const player=book({entityType:'session',payload:{bookId:b.entityId,kind:'listening',startedAt:'2026-10-13T10:00:00Z',endedAt:'2026-10-13T10:01:00Z',activeSeconds:60,timezone:'UTC',source:'player',offsetMinutes:180} as Operation['payload']});
    const op=parseOperation(player);
    assert.equal((await applyOperation(db,owner,op)).status,'accepted');
    const feed=await getChanges(db,owner,0,100);
    assert.equal((feed.changes.at(-1)!.payload as {offsetMinutes:number}).offsetMinutes,180);
    for(const offsetMinutes of [-841,841,1.5,'180',null])assert.throws(()=>parseOperation({...player,payload:{...player.payload,offsetMinutes}}));
    assert.throws(()=>parseOperation({...player,payload:{...player.payload,path:'private'}}));
    assert.deepEqual(await applyOperation(db,owner,op),await applyOperation(db,owner,op));
  }finally{db.close();}
});
test('pagination has no gaps despite interleaved tenants and independent device acknowledgements',async()=>{
  const db=new SqliteDatabase();try {
    for(let i=0;i<5;i++){await applyOperation(db,owner,book());await applyOperation(db,'other',book());}
    let after=0;const seen:number[]=[];
    do {const page=await getChanges(db,owner,after,2);seen.push(...page.changes.map(c=>c.sequence));after=page.cursor;if(!page.hasMore)break;}while(true);
    assert.equal(seen.length,5);assert.equal(new Set(seen).size,5);
    assert.equal((await getChanges(db,'unknown',0,100)).changes.length,0);
  } finally {db.close();}
});
test('database failure rolls back entity, receipt and change log together',async()=>{
  const db=new SqliteDatabase();try {
    db.sqlite.exec("CREATE TRIGGER fail_log BEFORE INSERT ON change_log BEGIN SELECT RAISE(ABORT,'injected failure'); END;");
    await assert.rejects(()=>applyOperation(db,owner,book()));
    for(const table of ['entities','operations','change_log']) assert.equal(db.sqlite.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get()?.n,0);
  } finally {db.close();}
});
test('HTTP authentication, device binding, revocation, validation and cursor checks',async()=>{
  const db=new SqliteDatabase();try {
    const token='a'.repeat(64);
    await db.prepare('INSERT INTO devices(id,owner_id,token_hash) VALUES(?,?,?)').bind(device,owner,await hashToken(token)).run();
    const request=(path:string,method='GET',payload?:unknown,auth=token)=>worker.fetch(new Request('http://localhost'+path,{method,headers:{Authorization:'Bearer '+auth},...(payload===undefined?{}:{body:JSON.stringify(payload)})}),{DB:db});
    assert.equal((await request('/v1/changes','GET',undefined,'bad')).status,401);
    assert.equal((await request('/v1/operations','POST',book({deviceId:randomUUID()}))).status,403);
    assert.equal((await request('/v1/operations','POST',{...book(),baseRevision:-1})).status,400);
    assert.equal((await request('/v1/changes?limit=-1')).status,400);
    assert.equal((await request('/v1/ack','POST',{cursor:999})).status,400);
    const op=book();assert.equal((await request('/v1/operations','POST',op)).status,200);
    const page=await (await request('/v1/changes')).json() as {cursor:number};
    assert.equal((await request('/v1/ack','POST',{cursor:page.cursor})).status,200);
    const second=randomUUID();await db.prepare('INSERT INTO devices(id,owner_id,token_hash) VALUES(?,?,?)').bind(second,owner,await hashToken('b'.repeat(64))).run();
    assert.equal((await request('/v1/changes','GET',undefined,'b'.repeat(64))).status,200);
    assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM device_cursors WHERE device_id=?').bind(second).first<{n:number}>())?.n,0);
    await db.prepare('UPDATE devices SET revoked_at=? WHERE id=?').bind(new Date().toISOString(),device).run();
    assert.equal((await request('/v1/changes')).status,401);
  } finally {db.close();}
});
test('session validation excludes negative, non-finite and impossible active time',()=>{
  const session=book({entityType:'session',payload:{bookId:randomUUID(),kind:'listening',startedAt:'2026-09-11T10:00:00Z',endedAt:'2026-09-11T10:01:00Z',activeSeconds:120,timezone:'UTC',source:'player'}});
  assert.throws(()=>parseOperation(session));
  assert.throws(()=>parseOperation({...session,payload:{...(session.payload as object),startedAt:'2026-02-31T10:00:00Z',endedAt:'2026-03-04T10:00:00Z',activeSeconds:60}}));
});
