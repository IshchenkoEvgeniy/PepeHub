import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {SqliteDatabase} from '../scripts/sqlite-adapter.ts';
import {handleMetadataApi} from '../integrations/obsidian/habit-timer/metadata-api.ts';
import {validNote,type NoteEntry} from '../integrations/obsidian/habit-timer/notes.ts';
import {readNoteMarkdown,applyNoteMarkdown,noteBlock} from '../integrations/obsidian/habit-timer/notes-markdown.ts';
import {emptyNoteState,captureNote,pendingNote,receiptNote,receiveNote} from '../integrations/obsidian/habit-timer/notes-state.ts';
const book=randomUUID();
const note=(extras:Partial<NoteEntry>={}):NoteEntry=>({id:randomUUID(),itemId:book,mediaType:'book',kind:'reader',title:'Глава 1',quote:'Цитата',text:'Комментарий',tags:['сюжет'],characters:['Матабар'],color:'yellow',anchor:{hash:'a'.repeat(64),chapter:0,start:10,end:16},origin:'app-reader',updatedAt:'2026-10-03T10:00:00.000Z',deleted:false,...extras});
async function setup(){
  const db=new SqliteDatabase();
  for(const file of ['001_pepehub_library.sql','003_pepehub_notes.sql'])db.sqlite.exec(readFileSync(new URL(`../integrations/obsidian/habit-timer/${file}`,import.meta.url),'utf8'));
  const call=(body?:unknown,after=0,profile='one')=>handleMetadataApi(new Request(`https://example.test/api/pepehub/library/notes?after=${after}`,body===undefined?{}:{method:'POST',body:JSON.stringify(body)}),db,profile);
  await handleMetadataApi(new Request('https://example.test/api/pepehub/library/snapshot',{method:'POST',body:JSON.stringify({snapshot:{version:1,ready:true,items:[{id:book,path:'Books/One.md',collectionId:'book',mediaType:'book',modifiedAt:1,values:{Title:'One'},fields:[]}],fields:[],collections:[]},receipts:[]})}),db,'one');
  return {db,call};
}
test('notes CAS, immutable lost-response retry, conflicts, deletion and account isolation',async()=>{
  const {db,call}=await setup();try {
    const value=note(),op={operationId:randomUUID(),baseRevision:0,entry:value};
    const first=await (await call({operations:[op]})).json();assert.equal(first.receipts[0].status,'applied');
    const changes=await Promise.all(['phone','vault'].map(text=>call({operations:[{operationId:randomUUID(),baseRevision:1,entry:{...value,text}}]})));
    assert.deepEqual((await Promise.all(changes.map(r=>r.json()))).map(r=>r.receipts[0].status).sort(),['applied','conflict']);
    assert.deepEqual(await (await call({operations:[op]})).json(),first);
    assert.equal((await call({operations:[{...op,entry:{...value,text:'reuse'}}]})).status,409);
    const feed=await (await call()).json(),latest=feed.records.at(-1);
    await call({operations:[{operationId:randomUUID(),baseRevision:latest.revision,entry:{...latest.entry,deleted:true}}]});
    assert.equal((await (await call(undefined,feed.cursor)).json()).records[0].entry.deleted,true);
    assert.equal((await (await call(undefined,0,'two')).json()).records.length,0);
    assert.equal((await call({operations:[op]},0,'two')).status,409);
  } finally{db.close();}
});
test('notes pagination handles large Unicode comments and rejects private paths/unknown items',async()=>{
  const {db,call}=await setup();try{
    for(let i=0;i<23;i++)assert.equal((await call({operations:[{operationId:randomUUID(),baseRevision:0,entry:note({text:'Ж'.repeat(i<4?100000:1)})}]})).status,200);
    let cursor=0;const ids=new Set<string>();do{const page=await (await call(undefined,cursor)).json();assert.ok(page.cursor>cursor);for(const row of page.records)ids.add(row.entry.id);cursor=page.cursor;if(!page.hasMore)break;}while(true);
    assert.equal(ids.size,23);
    for(const bad of [{anchor:{path:'C:/secret'}},{text:42},{tags:['x'.repeat(81)]},{itemId:randomUUID()},{kind:'audio'},{updatedAt:'yesterday'}])assert.ok([400,409].includes((await call({operations:[{operationId:randomUUID(),baseRevision:0,entry:{...note(),...bad}}]})).status));
    assert.equal(validNote(note()),true);
  }finally{db.close();}
});
test('linked audio ordinal anchors pass the real API; external IDs are rejected without persisting requests',async()=>{
  const {db,call}=await setup();try{
    await handleMetadataApi(new Request('https://example.test/api/pepehub/library/snapshot',{method:'POST',body:JSON.stringify({snapshot:{version:1,ready:true,items:[{id:book,path:'Audio/One.md',collectionId:'audiobook',mediaType:'audiobook',modifiedAt:1,values:{Title:'One'},fields:[]}],fields:[],collections:[]},receipts:[]})}),db,'one');
    const values=[0,1].map(trackIndex=>note({mediaType:'audiobook',kind:'audio',quote:'',origin:'app-audio',anchor:{positionMs:45000,noteKind:'thought',trackIndex}}));
    const operationId=randomUUID();
    const bad={...values[0]!,anchor:{...values[0]!.anchor,trackHash:`external:${randomUUID()}`}};
    assert.equal(validNote(bad),false);
    assert.equal((await call({operations:[{operationId,baseRevision:0,entry:bad}]})).status,400);
    assert.deepEqual((await (await call()).json()).records,[]);
    const operations=values.map((entry,i)=>({operationId:i===0?operationId:randomUUID(),baseRevision:0,entry}));
    const applied=await (await call({operations})).json();
    assert.deepEqual(applied.receipts.map((r:{status:string})=>r.status),['applied','applied']);
    const feed=await (await call()).json();
    assert.deepEqual(feed.records.map((r:{entry:NoteEntry})=>r.entry.anchor),values.map(v=>v.anchor));
    assert.deepEqual(await (await call({operations})).json(),applied);
  }finally{db.close();}
});
test('quotes, comments, labels and anchors roundtrip; visible Obsidian edits and CAS preserve both versions',()=>{
  const value=note({quote:'Цитата\n<!-- literal -->',text:'Два абзаца\n\nКомментарий & <'}),start='---\nTitle: One\n---\n';
  const applied=applyNoteMarkdown(start,value,null);assert.equal(applied.applied,true);
  assert.deepEqual(readNoteMarkdown(applied.content,book,'book',false).entries,[value]);
  assert.equal(applyNoteMarkdown(applied.content,value,null).content,applied.content);
  const edited=readNoteMarkdown(applied.content.replace('Комментарий &amp; &lt;','Правка'),book,'book');
  assert.equal(edited.entries[0]!.text,'Два абзаца\n\nПравка');assert.deepEqual(edited.entries[0]!.anchor,value.anchor);
  assert.equal(applyNoteMarkdown(edited.content,{...value,text:'phone'},value).applied,false);
  const removed=applyNoteMarkdown(applied.content,{...value,deleted:true},value);assert.equal(removed.applied,true);assert.equal(readNoteMarkdown(removed.content,book,'book',false).entries.length,0);
  assert.throws(()=>readNoteMarkdown(applied.content.replace('<!-- /pepehub-note:','<!-- BROKEN:'),book,'book'));
});
test('native Markdown notes retain original text, frontmatter and journal; imports do not duplicate',()=>{
  const head='---\r\nTitle: One\r\n---\r\n',text='## Мои заметки\r\nПервый абзац\r\n\r\n- мысль\r\n',journal='### 📖 Progress\r\n| Date | Time | Progress | % | Notes |\r\n|---|---|---|---|---|\r\n| 2026-10-03 | 00:10:00 | 12 | 42% | comment |\r\n',tail='## Персонажи\r\nГерой\r\n';
  const first=readNoteMarkdown(head+text+journal+tail,book,'book');
  assert.equal(first.entries.length,2);assert.equal(first.entries[0]!.text,text);assert.equal(first.entries[1]!.text,tail);
  assert.ok(first.content.startsWith(head));assert.ok(first.content.includes(journal));
  assert.deepEqual(readNoteMarkdown(first.content,book,'book'),first);
  const changed={...first.entries[0]!,text:'## Мои заметки\nИз телефона\n'};
  const next=applyNoteMarkdown(first.content,changed,first.entries[0]!);assert.equal(next.applied,true);assert.ok(next.content.includes(journal));assert.ok(next.content.includes(tail));
  assert.equal(readNoteMarkdown(next.content,book,'book').entries.length,2);
  const copy=readNoteMarkdown(first.content,randomUUID(),'book');assert.notEqual(copy.entries[0]!.id,first.entries[0]!.id);
});
test('durable note queue preserves offline edits during requests and conflict versions',()=>{
  const state=emptyNoteState(),value=note();captureNote(state,[value],new Set([book]));const op=pendingNote(state)[0]!;
  captureNote(state,[{...value,text:'offline'}],new Set([book]));receiptNote(state,{operationId:op.operationId,status:'applied',record:{entry:value,revision:1,sequence:1}});
  assert.equal(pendingNote(state)[0]!.entry.text,'offline');
  const remote={entry:{...value,text:'vault'},revision:2,sequence:2};assert.equal(receiveNote(state,remote),false);assert.equal(state.slots[value.id]!.value.text,'offline');assert.deepEqual(state.slots[value.id]!.conflict,remote);
});

test('imported quotes and comments stay literal instead of enabling Obsidian scripts or HTML',()=>{
  const value=note({quote:'```dataviewjs\nthrow new Error("do not run");\n```\n<img src="https://example.test/">',text:'`$= code` & literal &#96;'});
  const content=noteBlock(value);assert.ok(!content.includes('```dataviewjs'));assert.ok(!content.includes('<img'));assert.ok(!content.includes('`$='));
  assert.deepEqual(readNoteMarkdown(content,book,'book',false).entries,[value]);
  const changed=readNoteMarkdown(content.replace('literal','changed'),book,'book').entries[0]!;assert.equal(changed.quote,value.quote);assert.equal(changed.text,value.text.replace('literal','changed'));
});
