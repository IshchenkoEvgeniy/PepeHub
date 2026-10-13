import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {DurableState} from '../integrations/obsidian/habit-timer/durable-state.ts';

function fixture() {
  const files=new Map<string,string>();
  let fail=false,discard=false,writes=0;
  const adapter={
    exists:async(path:string)=>files.has(path),
    read:async(path:string)=>files.get(path)!,
    write:async(path:string,content:string)=>{
      writes++;
      if(discard)return;
      files.set(path,fail?content.slice(0,20):content);
      if(fail)throw new Error('interrupted write');
    },
  };
  const empty=()=>({version:1,cursor:0,slots:{} as Record<string,unknown>});
  const valid=(value:unknown)=>!!value&&typeof value==='object'&&(value as {version:number}).version===1;
  const open=()=>new DurableState(adapter,empty,valid);
  return {files,open,empty,setFail:(value:boolean)=>{fail=value;},setDiscard:()=>{discard=true;},writes:()=>writes};
}

test('an interrupted acknowledgement preserves the durable request UUID across restart',async()=>{
  const f=fixture(),store=f.open();
  const queued={...await store.read('state'),slots:{note:{operation:{operationId:randomUUID(),baseRevision:0,entry:{text:'offline'}}}}};
  await store.save('state',queued);
  f.setFail(true);
  await assert.rejects(store.save('state',{...queued,cursor:1,slots:{}}),/interrupted/);
  assert.deepEqual(await f.open().read('state'),queued);
  f.setFail(false);
  const reopened=f.open();await reopened.read('state');
  await reopened.save('state',{...queued,cursor:1,slots:{}});
  assert.equal((await f.open().read('state')).cursor,1);
});
test('a checksum mismatch uses the last verified state and two damaged copies never reset the queue',async()=>{
  const f=fixture(),store=f.open();
  const first=await store.read('state');await store.save('state',first);
  await store.save('state',{...first,cursor:7});
  const corrupted=JSON.parse(f.files.get('state.0')!);corrupted.payload=JSON.stringify({...first,cursor:999});
  f.files.set('state.0',JSON.stringify(corrupted));
  assert.deepEqual(await f.open().read('state'),first);
  f.files.set('state.1','broken');f.files.set('state',JSON.stringify(first));
  const before=[...f.files];
  await assert.rejects(f.open().read('state'),/обе копии/);
  assert.deepEqual([...f.files],before);
});
test('legacy queues migrate without changing UUIDs and identical saves do not rewrite history',async()=>{
  const f=fixture(),legacy={...f.empty(),slots:{note:{operation:{operationId:randomUUID()}}}};
  f.files.set('state',JSON.stringify(legacy));
  const store=f.open(),loaded=await store.read('state');assert.deepEqual(loaded,legacy);
  await store.save('state',loaded);await store.save('state',loaded);
  assert.equal(f.writes(),1);
  assert.deepEqual(await f.open().read('state'),legacy);
  assert.equal(f.files.get('state'),JSON.stringify(legacy));
});
test('a successful but discarded adapter write is detected before state is acknowledged',async()=>{
  const f=fixture(),store=f.open();await store.read('state');f.setDiscard();
  await assert.rejects(store.save('state',f.empty()));
  assert.equal(f.files.size,0);
});
