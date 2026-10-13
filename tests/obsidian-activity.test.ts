import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {SqliteDatabase} from '../scripts/sqlite-adapter.ts';
import {handleMetadataApi} from '../integrations/obsidian/habit-timer/metadata-api.ts';
import {validActivity,type ActivityEntry} from '../integrations/obsidian/habit-timer/activity.ts';
import {readActivityMarkdown,applyActivityMarkdown,activityRow} from '../integrations/obsidian/habit-timer/activity-markdown.ts';
import {captureActivity,emptyActivityState,pendingActivity,receiptActivity,receiveActivity} from '../integrations/obsidian/habit-timer/activity-state.ts';
const book=randomUUID();
const entry=(extras:Partial<ActivityEntry>={}):ActivityEntry=>({id:randomUUID(),itemId:book,mediaType:'book',day:'2026-10-03',durationMs:123456,progress:17,unit:'pages',mediaMs:0,startedAt:null,endedAt:null,offsetMinutes:null,note:'Заметка | с разделителем',origin:'obsidian',deleted:false,...extras});
async function setup(){
  const db=new SqliteDatabase();
  for(const file of ['001_pepehub_library.sql','002_pepehub_activity.sql'])db.sqlite.exec(readFileSync(new URL(`../integrations/obsidian/habit-timer/${file}`,import.meta.url),'utf8'));
  const call=(body?:unknown,after=0,profile='one')=>handleMetadataApi(new Request(`https://example.test/api/pepehub/library/activity?after=${after}`,body===undefined?{}:{method:'POST',body:JSON.stringify(body)}),db,profile);
  const snapshot={version:1,ready:true,items:[{id:book,path:'Books/One.md',collectionId:'book',mediaType:'book',modifiedAt:1,values:{Title:'One'},fields:[]}],fields:[],collections:[]};
  await handleMetadataApi(new Request('https://example.test/api/pepehub/library/snapshot',{method:'POST',body:JSON.stringify({snapshot,receipts:[]})}),db,'one');
  return {db,call};
}
test('journal CAS is atomic, replay is durable, tombstones propagate and profiles stay isolated',async()=>{
  const {db,call}=await setup();try{
    const value=entry(),op={operationId:randomUUID(),baseRevision:0,entry:value};
    const create=await (await call({operations:[op]})).json();assert.equal(create.receipts[0].status,'applied');
    assert.equal(create.receipts[0].record.revision,1);
    const edits=await Promise.all([1,2].map(n=>call({operations:[{operationId:randomUUID(),baseRevision:1,entry:{...value,note:`edit ${n}`}}]})));
    assert.deepEqual((await Promise.all(edits.map(r=>r.json()))).map(r=>r.receipts[0].status).sort(),['applied','conflict']);
    assert.deepEqual(await (await call({operations:[op]})).json(),create);
    assert.equal((await call({operations:[{...op,entry:{...value,note:'reused'}}]})).status,409);
    const feed=await (await call()).json();assert.equal(feed.records.length,2);
    const latest=feed.records.at(-1);await call({operations:[{operationId:randomUUID(),baseRevision:latest.revision,entry:{...latest.entry,deleted:true}}]});
    const delta=await (await call(undefined,feed.cursor)).json();assert.equal(delta.records.length,1);assert.equal(delta.records[0].entry.deleted,true);
    assert.equal((await (await call(undefined,0,'two')).json()).records.length,0);
    assert.equal((await call({operations:[op]},0,'two')).status,409);
  }finally{db.close();}
});
test('pagination carries every change once; malformed dates/fields/unknown books fail safely',async()=>{
  const {db,call}=await setup();try{
    for(let batch=0;batch<3;batch++)assert.equal((await call({operations:Array.from({length:40},()=>({operationId:randomUUID(),baseRevision:0,entry:entry()}))})).status,200);
    const first=await (await call()).json(),second=await (await call(undefined,first.cursor)).json();
    assert.equal(first.records.length,100);assert.equal(first.hasMore,true);assert.equal(second.records.length,20);assert.equal(second.hasMore,false);
    assert.equal(new Set([...first.records,...second.records].map(r=>r.entry.id)).size,120);
    for(const bad of [{day:'2026-13-99'},{day:'2026-02-30'},{durationMs:-1},{unit:'seconds'},{itemId:randomUUID()},{privatePath:'C:/secret'}]) {
      const response=await call({operations:[{operationId:randomUUID(),baseRevision:0,entry:{...entry(),...bad}}]});assert.ok([400,409].includes(response.status));
    }
    assert.equal(validActivity(entry({day:'invalid'})),false);
  }finally{db.close();}
});
test('legacy duplicate rows receive stable UUIDs without changing user cells or other tables',()=>{
  const row='| 2026-10-03 | 00:10:00 | 12 | (Total: 42/100 - 42%) | мысль \\| идея |';
  const content=`My notes\n### 📖 Progress\n| Date | Time | Progress | % | Notes |\n|---|---|---|---|---|\n${row}\n${row}\n### Other\n${row}\n`;
  const first=readActivityMarkdown(content,book,'book');assert.equal(first.entries.length,2);assert.notEqual(first.entries[0]!.id,first.entries[1]!.id);
  const next=readActivityMarkdown(first.content,book,'book');assert.deepEqual(next,first);assert.ok(first.content.includes(`${row} <!--`));assert.ok(first.content.endsWith(`### Other\n${row}\n`));
  assert.equal(first.entries[0]!.note,'мысль | идея');
  const copied=readActivityMarkdown(first.content,randomUUID(),'book');assert.notEqual(copied.entries[0]!.id,first.entries[0]!.id);
});
test('Markdown roundtrip preserves milliseconds, audio speed, timezone and escaped notes',()=>{
  const value=entry({mediaType:'audiobook',origin:'app-audio',durationMs:123456,progress:4.1152,mediaMs:246912,unit:'minutes',offsetMinutes:180,startedAt:'2026-10-02T21:05:00.000Z',endedAt:'2026-10-02T21:07:03.456Z'});
  const applied=applyActivityMarkdown('User text\n',value,null);assert.equal(applied.applied,true);
  assert.deepEqual(readActivityMarkdown(applied.content,book,'audiobook').entries,[value]);
  assert.equal(applyActivityMarkdown(applied.content,value,null).content,applied.content);
  const changed={...value,durationMs:600000,note:'changed'};
  assert.equal(applyActivityMarkdown(applied.content,changed,value).applied,true);
  const concurrent=applied.content.replace('00:02:03','00:03:00');
  assert.equal(applyActivityMarkdown(concurrent,changed,value).applied,false);
  const removed=applyActivityMarkdown(applied.content,{...value,deleted:true},value);assert.equal(readActivityMarkdown(removed.content,book,'audiobook').entries.length,0);
  assert.equal(applyActivityMarkdown(removed.content,{...value,deleted:true},value).applied,true);
  assert.ok(activityRow(value).includes('мин.'));
});
test('local edits during a lost request survive acknowledgements; conflicts retain both versions',()=>{
  const state=emptyActivityState(),value=entry();captureActivity(state,[value],new Set([book]));
  const operation=pendingActivity(state)[0]!;assert.deepEqual(pendingActivity(state),[operation]);
  captureActivity(state,[{...value,note:'offline edit'}],new Set([book]));
  receiptActivity(state,{operationId:operation.operationId,status:'applied',record:{entry:value,revision:1,sequence:1}});
  const pending=pendingActivity(state)[0]!;assert.equal(pending.baseRevision,1);assert.equal(pending.entry.note,'offline edit');
  const remote={entry:{...value,note:'other device'},revision:2,sequence:2};assert.equal(receiveActivity(state,remote),false);
  assert.equal(state.slots[value.id]!.value.note,'offline edit');assert.deepEqual(state.slots[value.id]!.conflict,remote);
  assert.equal(pendingActivity(state).length,0);
});

 test('CRLF frontmatter and multiline or literal pipe notes survive the journal roundtrip',()=>{
  const value=entry({note:'Первая\nВторая \\ | -'}), content='---\r\nTitle: One\r\nReading time: "00:01:00"\r\n---\r\nUser text\r\n';
  const applied=applyActivityMarkdown(content,value,null);
  assert.ok(applied.content.includes('Reading time: "00:03:03"'));
  assert.ok(!/(?<!\r)\n/.test(applied.content));
  assert.deepEqual(readActivityMarkdown(applied.content,book,'book').entries,[value]);
  const dash=entry({note:'-'});
  assert.deepEqual(readActivityMarkdown(applyActivityMarkdown('',dash,null).content,book,'book').entries,[dash]);
 });

 test('Russian legacy journals share stable IDs and preserve the original section',()=>{
   for(const heading of ['### 📖 Журнал чтения','### 🎧 Журнал прослушивания']){
     const content=`${heading}\n| Дата | Время | Прочитано | Прогресс | Заметки |\n|---|---|---|---|---|\n| 2026-05-04 | 00:16:21 | 10 | 10/94 | - |\n`;
     const first=readActivityMarkdown(content,book,'book'); assert.equal(first.entries.length,1);
     assert.deepEqual(readActivityMarkdown(first.content,book,'book'),first);
     assert.ok(first.content.startsWith(heading));
   }
 });

test('automatically prefilled reading time is derived from synced rows and is not counted twice',()=>{
  const value=entry({durationMs:600000});
  const content='---\nReading time: "00:10:00"\npepehub_time_from_journal: true\n---\n';
  const first=applyActivityMarkdown(content,value,null);assert.ok(first.content.includes('Reading time: "00:10:00"'));
  const second=applyActivityMarkdown(first.content,entry({durationMs:300000}),null);assert.ok(second.content.includes('Reading time: "00:15:00"'));
});

test('malformed synced journal rows stop capture instead of becoming tombstones',()=>{
  const value=entry(),content=applyActivityMarkdown('',value,null).content;
  const state=emptyActivityState();captureActivity(state,[value],new Set([book]));
  const operation=pendingActivity(state)[0]!;
  receiptActivity(state,{operationId:operation.operationId,status:'applied',record:{entry:value,revision:1,sequence:1}});
  for(const broken of [
    content.replace('00:02:03','invalid'),
    content.replace('2026-10-03','2026-02-30'),
    content.replace('### 📖 Progress','### Other'),
    content.replace(/:[A-Za-z0-9+/=]+ -->/,':broken -->'),
    content.replace(`pepehub-activity:${value.id}:`,`pepehub-activity:${randomUUID()}:`),
    content.replace(`pepehub-activity:${value.id}:`,`pepehub-activity:${value.id}:!`),
  ]) {
    assert.throws(()=>{const parsed=readActivityMarkdown(broken,book,'book');captureActivity(state,parsed.entries,new Set([book]));},/PepeHub:/);
    assert.equal(state.slots[value.id]!.value.deleted,false);
    assert.deepEqual(pendingActivity(state),[]);
  }
  const removed=applyActivityMarkdown(content,{...value,deleted:true},value);
  captureActivity(state,readActivityMarkdown(removed.content,book,'book').entries,new Set([book]));
  assert.equal(pendingActivity(state)[0]!.entry.deleted,true);
});
