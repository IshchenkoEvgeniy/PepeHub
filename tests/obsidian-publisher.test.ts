import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {registerHooks} from 'node:module';
import {randomUUID} from 'node:crypto';
import * as ts from 'typescript';
import {TFile,setTransport} from './support/library-publisher-mock.ts';
import {SqliteDatabase} from '../scripts/sqlite-adapter.ts';
import {handleMetadataApi} from '../integrations/obsidian/habit-timer/metadata-api.ts';

const root=new URL('../integrations/obsidian/habit-timer/',import.meta.url);
const mock=new URL('./support/library-publisher-mock.ts',import.meta.url).href;
registerHooks({
  resolve(specifier,context,next) {
    if(specifier==='obsidian'||context.parentURL?.startsWith(root.href)&&specifier==='../types')return {url:mock,shortCircuit:true};
    if(context.parentURL?.startsWith(root.href)&&specifier.startsWith('./pepehub-')) {
      const stem=specifier.slice(10);return {url:new URL(`${stem.endsWith('-service')?'pepehub-':''}${stem}${stem.endsWith('-service')?'.ts.template':'.ts'}`,root).href,shortCircuit:true};
    }
    return next(specifier,context);
  },
  load(url,context,next) {
    if(url.endsWith('.ts.template'))return {format:'module',shortCircuit:true,source:ts.transpileModule(readFileSync(new URL(url),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2023,module:ts.ModuleKind.ESNext}}).outputText};
    return next(url,context);
  },
});
const {PepeHubLibraryService}=await import(new URL('pepehub-library-service.ts.template',root).href);

test('installable library publisher reads only changed files and sends delta edits/deletions; stale cursor recovers',async()=>{
  const db=new SqliteDatabase();db.sqlite.exec(readFileSync(new URL('001_pepehub_library.sql',root),'utf8'));
  const files=new Map<string,TFile&{stat:{mtime:number;size:number}}>(),contents=new Map<string,string>();
  const events=new Map<string,Array<(file:TFile,old?:string)=>void>>();let reads=0;
  const put=(path:string,title:string)=>{
    const text=JSON.stringify({pepehub_id:randomUUID(),Title:title,Type:'book'});
    const file=Object.assign(new TFile(),{path,stat:{mtime:1,size:text.length}});files.set(path,file);contents.set(path,text);return file;
  };
  const a=put('Books/A.md','One'),b=put('Books/B.md','Two');
  const emit=(name:string,file:TFile)=>events.get(name)?.forEach(fn=>fn(file));
  const publications:Array<{path:string;body:Record<string,unknown>}>=[];
  setTransport(async options=>{
    const path=new URL(options.url).pathname.replace('/api/pepehub/library','');
    if(options.body)publications.push({path,body:JSON.parse(options.body)});
    const response=await handleMetadataApi(new Request(options.url,options.body?{method:'POST',body:options.body}:{}),db,'one');
    return {status:response.status,json:await response.json()};
  });
  const vault={getMarkdownFiles:()=>[...files.values()],read:async(file:TFile)=>{reads++;return contents.get(file.path);},
    on:(name:string,fn:(file:TFile)=>void)=>{events.set(name,[...(events.get(name)??[]),fn]);return {name,fn};},
    offref:(ref:{name:string;fn:(file:TFile)=>void})=>events.set(ref.name,(events.get(ref.name)??[]).filter(fn=>fn!==ref.fn)),
    adapter:{},configDir:'.obsidian'};
  const service=new PepeHubLibraryService({manifest:{id:'habit-timer'},settings:{cloudflareWorkerUrl:'https://test',cloudflareApiToken:'secret',pepehubLibrarySyncSeconds:30,libraryPropertyAliases:{},mediaCollections:[{id:'book',enabled:true,folder:'Books'}]},app:{vault}});
  service.activity.sync=service.notes.sync=async()=>{};
  const globals=globalThis as unknown as {window:unknown};const previous=globals.window;globals.window=globalThis;
  const settle=async()=>{for(let n=0;service.syncing&&n<100;n++)await new Promise(resolve=>setTimeout(resolve,5));assert.equal(service.syncing,false);};
  try {
    service.start();await settle();assert.equal(publications.length,1);assert.equal(reads,2);
    reads=0;await service.sync();assert.equal(reads,0);assert.equal(publications.length,1);
    const changed=JSON.parse(contents.get(a.path)!);changed.Title='Changed';contents.set(a.path,JSON.stringify(changed));a.stat.mtime++;a.stat.size=contents.get(a.path)!.length;emit('modify',a);
    await service.sync();assert.equal(reads,1);assert.equal(publications.at(-1)!.path,'/delta');assert.equal((publications.at(-1)!.body.changes as unknown[]).length,1);
    files.delete(b.path);emit('delete',b);await service.sync();
    assert.deepEqual(publications.at(-1)!.body.changes,[{id:JSON.parse(contents.get(b.path)!).pepehub_id,item:null}]);
    // A competing publisher advances the index. The next failed delta is
    // retried through a full, idempotent reconciliation, never acknowledged early.
    service.index.cursor=0;changed.Title='After stale';contents.set(a.path,JSON.stringify(changed));a.stat.mtime++;emit('modify',a);
    const warn=console.error;console.error=()=>{};try {await service.sync();}finally{console.error=warn;}
    assert.equal(service.index,null);await service.sync();assert.equal(publications.at(-1)!.path,'/snapshot');
    const latest=await handleMetadataApi(new Request('https://test/api/pepehub/library'),db,'one');
    const snapshot=await latest.json();assert.equal(snapshot.items.length,1);assert.equal(snapshot.items[0].values.Title,'After stale');
    const count=publications.length;await service.sync();assert.equal(publications.length,count);
  }finally{service.stop();globals.window=previous;db.close();}
});
