import { InputError, parseOperation } from '../../../contracts/protocol.ts';
import type { Database } from './database.ts';
import { applyOperation, getChanges, ReusedOperationError } from './store.ts';
export interface Env { DB: Database }
export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2,'0')).join('');
}
function json(body: unknown, status = 200): Response {
  return Response.json(body,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
}
async function body(request: Request): Promise<unknown> {
  // Enforce a bound even when Content-Length is absent or forged.
  const reader = request.body?.getReader();
  if (!reader) throw new InputError('Missing JSON body');
  let size=0; const chunks: Uint8Array[]=[];
  while (true) {
    const next=await reader.read(); if(next.done) break;
    size+=next.value.length;
    if(size>32768) { await reader.cancel(); throw new InputError('Body exceeds 32 KiB'); }
    chunks.push(next.value);
  }
  const bytes=new Uint8Array(size); let offset=0;
  for(const chunk of chunks) { bytes.set(chunk,offset);offset+=chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)); } catch { throw new InputError('Invalid JSON'); }
}
function integer(raw: string | null, fallback: number, min: number, max: number): number {
  if(raw===null) return fallback;
  if(!/^\d+$/.test(raw)) throw new InputError('Invalid integer');
  const n=Number(raw); if(!Number.isSafeInteger(n)||n<min||n>max) throw new InputError('Integer out of range');
  return n;
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url=new URL(request.url);
      if(url.pathname==='/health' && request.method==='GET') return json({ok:true,service:'pepehub-sync',schemaVersion:1});
      const authorization=request.headers.get('Authorization') ?? '';
      if(!authorization.startsWith('Bearer ') || authorization.length>1024) return json({error:'unauthorized'},401);
      const device=await env.DB.prepare('SELECT id,owner_id FROM devices WHERE token_hash=? AND revoked_at IS NULL').bind(await hashToken(authorization.slice(7))).first<{id:string;owner_id:string}>();
      if(!device) return json({error:'unauthorized'},401);
      if(url.pathname==='/v1/me' && request.method==='GET') return json({deviceId:device.id,ownerId:device.owner_id});
      if(url.pathname==='/v1/operations' && request.method==='POST') {
        const operation=parseOperation(await body(request));
        if(operation.deviceId!==device.id) return json({error:'device_mismatch'},403);
        return json(await applyOperation(env.DB,device.owner_id,operation));
      }
      if(url.pathname==='/v1/changes' && request.method==='GET') {
        return json(await getChanges(env.DB,device.owner_id,integer(url.searchParams.get('after'),0,0,Number.MAX_SAFE_INTEGER),integer(url.searchParams.get('limit'),100,1,200)));
      }
      if(url.pathname==='/v1/ack' && request.method==='POST') {
        const input=await body(request) as {cursor?:unknown};
        if(!input || typeof input!=='object' || !Number.isSafeInteger(input.cursor) || (input.cursor as number)<0) throw new InputError('Invalid cursor');
        const cursor=input.cursor as number;
        if(cursor>0) {
          const visible=await env.DB.prepare('SELECT sequence FROM change_log WHERE owner_id=? AND sequence=?').bind(device.owner_id,cursor).first();
          if(!visible) throw new InputError('Unknown cursor');
        }
        await env.DB.prepare('INSERT INTO device_cursors(device_id,sequence) VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)').bind(device.id,cursor).run();
        return json({ok:true});
      }
      return json({error:'not_found'},404);
    } catch(error) {
      if(error instanceof InputError) return json({error:'invalid_input',message:error.message},400);
      if(error instanceof ReusedOperationError) return json({error:'operation_id_reused'},409);
      console.error('Sync request failed',error instanceof Error ? error.name : 'unknown');
      return json({error:'internal_error'},500);
    }
  }
};
