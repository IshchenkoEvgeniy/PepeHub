import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {registerHooks} from 'node:module';
import * as ts from 'typescript';
import {TFile, Modal, Notice} from './support/obsidian-mock.ts';
import {activityRow} from '../integrations/obsidian/habit-timer/activity-markdown.ts';
import type {ActivityEntry} from '../integrations/obsidian/habit-timer/activity.ts';
import {noteBlock} from '../integrations/obsidian/habit-timer/notes-markdown.ts';
import type {NoteEntry} from '../integrations/obsidian/habit-timer/notes.ts';

// Exercise installable services without modifying the user's Obsidian plugin.
const bridgeRoot = new URL('../integrations/obsidian/habit-timer/', import.meta.url);
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === 'obsidian') return {url: new URL('./support/obsidian-mock.ts', import.meta.url).href, shortCircuit: true};
    if (context.parentURL?.startsWith(bridgeRoot.href) && specifier.startsWith('./pepehub-')) {
      const stem = specifier.slice('./pepehub-'.length);
      return {url: new URL(`${stem}${stem.endsWith('-service') ? '.ts.template' : '.ts'}`, bridgeRoot).href, shortCircuit: true};
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith('.ts.template')) return {
      format: 'module', shortCircuit: true,
      source: ts.transpileModule(readFileSync(new URL(url), 'utf8'), {
        compilerOptions: {target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.ESNext},
      }).outputText,
    };
    return nextLoad(url, context);
  },
});
const {PepeHubActivityService} = await import(new URL('pepehub-activity-service.ts.template', bridgeRoot).href);
const {PepeHubNoteService} = await import(new URL('pepehub-notes-service.ts.template', bridgeRoot).href);

for (const kind of ['activity', 'notes'] as const) {
  for (const useRemote of [true, false]) {
    for (const conflictChanged of [true, false]) {
      test(`${kind} review ${conflictChanged ? 'rejects a stale conflict' : 'accepts the displayed conflict'} (${useRemote ? 'remote' : 'local'})`, async () => {
        Notice.messages = [];
        const itemId = randomUUID(), id = randomUUID(), file = new TFile(); file.path = 'Books/One.md';
        const value = kind === 'activity'
          ? {id, itemId, mediaType: 'book', day: '2026-10-03', durationMs: 600000, progress: 10, unit: 'pages', mediaMs: 0, startedAt: null, endedAt: null, offsetMinutes: null, note: 'Local', origin: 'obsidian', deleted: false} satisfies ActivityEntry
          : {id, itemId, mediaType: 'book', kind: 'reader', title: 'Chapter', quote: 'Quote', text: 'Local', tags: [], characters: [], color: 'yellow', anchor: {}, origin: 'obsidian', updatedAt: '2026-10-03T10:00:00.000Z', deleted: false} satisfies NoteEntry;
        const remoteEntry = kind === 'activity' ? {...value, note: 'Remote 2'} : {...value, text: 'Remote 2'};
        const state = {version: 1, cursor: 2, slots: {[id]: {value, synced: null, revision: 1, conflict: {entry: remoteEntry, revision: 2, sequence: 2}}}};
        let stored = JSON.stringify(state), writes = 0;
        const checkpoints=new Map<string,string>();
        let content = kind === 'activity' ? `### Progress\n${activityRow(value as ActivityEntry)}\n` : noteBlock(value as NoteEntry);
        const plugin = {manifest: {id: 'habit-timer'}, settings: {cloudflareWorkerUrl: 'https://example.test', cloudflareApiToken: 'token'}, app: {
          vault: {configDir: '.obsidian', adapter: {exists: async (path:string) => !/\.[01]$/.test(path)||checkpoints.has(path), read: async (path:string) => checkpoints.get(path) ?? stored, write: async (path: string, text: string) => {checkpoints.set(path,text);stored = JSON.parse(text).payload; writes++;}},
            getMarkdownFiles: () => [file], process: async (_file: TFile, transform: (text: string) => string) => {content = transform(content); writes++;}},
          metadataCache: {getFileCache: () => ({frontmatter: {pepehub_id: itemId}})},
        }};
        const service = kind === 'activity' ? new PepeHubActivityService(plugin) : new PepeHubNoteService(plugin);
        await service.review();
        const newer = {...state, cursor: 3, slots: {[id]: {...state.slots[id]!, conflict: {
          entry: kind === 'activity' ? {...value, note: 'Remote 3'} : {...value, text: 'Remote 3'}, revision: 3, sequence: 3,
        }}}};
        stored = JSON.stringify(conflictChanged ? newer : state);
        const before = content;
        const buttons = Modal.last.contentEl.children[0]!.children.filter(child => child.onclick);
        await buttons[useRemote ? 0 : 1]!.onclick!();
        if (conflictChanged) {
          assert.deepEqual(JSON.parse(stored), newer);
          assert.equal(content, before);
          assert.equal(writes, 0);
          assert.ok(Notice.messages.some(message => message.includes('Откройте список конфликтов заново')));
        } else {
          const accepted = JSON.parse(stored);
          assert.equal(accepted.cursor, 2);
          assert.equal(accepted.slots[id].revision, 2);
          assert.deepEqual(accepted.slots[id].synced, remoteEntry);
          assert.deepEqual(accepted.slots[id].value, useRemote ? remoteEntry : value);
          assert.equal(accepted.slots[id].conflict, undefined);
          assert.equal(writes, useRemote ? 2 : 1);
          assert.equal(Notice.messages.length, 0);
        }
      });
    }
  }
}

for (const kind of ['activity', 'notes'] as const) {
  test(`${kind} replays the original request after an interrupted receipt write and service restart`,async()=>{
    const itemId=randomUUID(),file=new TFile();file.path='Books/One.md';
    let content=kind==='activity'?'### Progress\n| 2026-10-03 | 00:10:00 | 10 | - | Native |\n':'Native notes\n';
    const states=new Map<string,string>(),ids:string[]=[];
    let interrupt=true;
    const plugin={manifest:{id:'habit-timer'},settings:{cloudflareWorkerUrl:'https://example.test',cloudflareApiToken:'token'},app:{vault:{
      configDir:'.obsidian',adapter:{exists:async(path:string)=>states.has(path),read:async(path:string)=>states.get(path),write:async(path:string,text:string)=>{
        if(ids.length&&interrupt){states.set(path,text.slice(0,30));throw new Error('interrupted receipt');}
        states.set(path,text);
      }},
      getAbstractFileByPath:()=>file,read:async()=>content,process:async(_file:TFile,transform:(text:string)=>string)=>{content=transform(content);},
    }}};
    const snapshot={version:1,ready:true,items:[{id:itemId,path:file.path,mediaType:'book'}]};
    const request=async(_path:string,body?:{operations:{operationId:string;entry:ActivityEntry|NoteEntry}[]})=>{
      if(body){ids.push(...body.operations.map(op=>op.operationId));return {version:1,receipts:body.operations.map(op=>({operationId:op.operationId,status:'applied',record:{entry:op.entry,revision:1,sequence:1}}))};}
      return {version:1,records:[],cursor:1,hasMore:false};
    };
    const open=()=>kind==='activity'?new PepeHubActivityService(plugin):new PepeHubNoteService(plugin);
    await assert.rejects(open().sync(snapshot,request),/interrupted receipt/);
    const stable=content;interrupt=false;
    await open().sync(snapshot,request);
    assert.equal(ids.length,2);assert.equal(ids[0],ids[1]);assert.equal(content,stable);
    await open().sync(snapshot,request);assert.equal(ids.length,2);
  });
  test(`installed ${kind} service preserves state on damaged content and does not delete an unavailable file`, async () => {
    const itemId = randomUUID(), file = new TFile(); file.path = 'Books/One.md';
    let content = kind === 'activity' ? '### Progress\n| 2026-10-03 | 00:10:00 | 10 | - | Native |\n' : 'Native notes\n';
    let available = true;
    const states = new Map<string, string>(); let requests = 0, posts = 0;
    const plugin = {manifest: {id: 'habit-timer'}, settings: {cloudflareWorkerUrl: 'https://example.test', cloudflareApiToken: 'token'}, app: {vault: {
      configDir: '.obsidian', adapter: {exists: async (path: string) => states.has(path), read: async (path: string) => states.get(path), write: async (path: string, text: string) => {states.set(path, text);}},
      getAbstractFileByPath: () => available ? file : null, read: async () => content, process: async (_file: TFile, transform: (text: string) => string) => {content = transform(content);},
    }}};
    const service = kind === 'activity' ? new PepeHubActivityService(plugin) : new PepeHubNoteService(plugin);
    const snapshot = {version: 1, ready: true, items: [{id: itemId, path: file.path, mediaType: 'book'}]};
    const request = async (_path: string, body?: {operations: {operationId: string; entry: ActivityEntry | NoteEntry}[]}) => {
      requests++;
      if (body) posts++;
      return body ? {version: 1, receipts: body.operations.map(op => ({operationId: op.operationId, status: 'applied', record: {entry: op.entry, revision: 1, sequence: 1}}))}
        : {version: 1, records: [], cursor: 1, hasMore: false};
    };
    await service.sync(snapshot, request);
    const before = [...states.values()], count = requests;
    content = kind === 'activity' ? content.replace('00:10:00', 'invalid') : content.replace('<!-- /pepehub-note:', '<!-- /pepehub-note:broken-');
    await assert.rejects(service.sync(snapshot, request), /PepeHub:/);
    assert.deepEqual([...states.values()], before);
    assert.equal(requests, count);
    available = false;
    await service.sync(snapshot, request);
    assert.deepEqual([...states.values()], before);
    assert.equal(posts, 1);
  });
}
