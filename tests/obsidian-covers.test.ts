import {test} from 'node:test';
import assert from 'node:assert/strict';
import {handlePrivateCover,digestCover,validCoverAsset,type PrivateCoverBucket} from '../integrations/obsidian/habit-timer/covers.ts';
const png=Uint8Array.from(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==','base64'));
test('covers are authenticated by the router, profile scoped, content addressed and cached without public URLs',async()=>{
  const stored=new Map<string,ArrayBuffer>();let puts=0;
  const bucket:PrivateCoverBucket={head:async k=>stored.has(k)?{}:null,get:async k=>stored.has(k)?{body:new Response(stored.get(k)).body!,httpEtag:'etag'}:null,put:async(k,v)=>{puts++;stored.set(k,v);}};
  const hash=await digestCover(png.buffer);
  const call=(method:string,profile='one',body?:Uint8Array,path=hash)=>handlePrivateCover(new Request(`https://example.test/api/pepehub/library/covers/${path}`,{method,headers:{'Content-Type':'image/png'},...(body?{body:new Uint8Array(body).buffer}: {})}),profile,bucket);
  assert.equal((await call('GET')).status,404);assert.equal((await call('POST','one',png)).status,200);assert.equal((await call('POST','one',png)).status,200);assert.equal(puts,1);
  const get=await call('GET');assert.deepEqual(new Uint8Array(await get.arrayBuffer()),png);assert.equal(get.headers.get('Cache-Control'),'private, max-age=86400');assert.equal((await call('GET','two')).status,404);
  assert.equal((await call('POST','one',png,'a'.repeat(64))).status,400);
  assert.equal((await call('POST','one',new Uint8Array(2097153))).status,413);
  assert.equal((await call('POST','one',new Uint8Array([1,2,3]))).status,415);
  assert.equal(validCoverAsset({hash,bytes:png.length,mime:'image/png'}),true);
  assert.equal(validCoverAsset({hash:'../file',bytes:png.length,mime:'image/png'}),false);
  assert.ok([...stored.keys()].every(key=>key.startsWith('pepehub-covers/')&&!key.includes('one')));
});
