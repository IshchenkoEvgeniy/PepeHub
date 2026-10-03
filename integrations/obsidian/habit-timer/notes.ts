import { validId, equalValue } from './metadata.ts';
export interface NoteEntry {
  id:string; itemId:string; mediaType:'book'|'audiobook'; kind:'reader'|'audio'|'markdown';
  title:string; quote:string; text:string; tags:string[]; characters:string[]; color:string;
  anchor:Record<string,string|number>; origin:'app-reader'|'app-audio'|'obsidian'; updatedAt:string; deleted:boolean;
}
export interface NoteRecord {entry:NoteEntry;revision:number;sequence:number;}
export interface NoteOperation {operationId:string;baseRevision:number;entry:NoteEntry;}
export const sameNote=equalValue;
export function validNote(value:unknown):value is NoteEntry {
  if(!value || typeof value!=='object'||Array.isArray(value))return false;
  const e=value as NoteEntry;
  const keys=['id','itemId','mediaType','kind','title','quote','text','tags','characters','color','anchor','origin','updatedAt','deleted'];
  const text=(v:unknown,max:number)=>typeof v==='string'&&v.length<=max;
  const labels=(v:unknown)=>Array.isArray(v)&&v.length<=40&&v.every(x=>text(x,80));
  if(Object.keys(e).length!==keys.length||Object.keys(e).some(k=>!keys.includes(k)))return false;
  if(!e.anchor||typeof e.anchor!=='object'||Array.isArray(e.anchor)||Object.keys(e.anchor).some(k=>!['hash','chapter','start','end','positionMs','trackHash','trackIndex','noteKind'].includes(k)))return false;
  for(const [key,v] of Object.entries(e.anchor)) {
    if(['hash','trackHash'].includes(key)){if(typeof v!=='string'||!(/^[a-f0-9]{64}$/).test(v))return false;}
    else if(key==='noteKind'){if(!['thought','quote','character'].includes(String(v)))return false;}
    else if(typeof v!=='number'||!Number.isSafeInteger(v)||v < (key==='chapter'?-1:0)||v>1e12)return false;
  }
  return validId(e.id)&&validId(e.itemId)&&['book','audiobook'].includes(e.mediaType)&&['reader','audio','markdown'].includes(e.kind)
    &&(e.kind!=='reader'||e.mediaType==='book')&&(e.kind!=='audio'||e.mediaType==='audiobook')
    &&text(e.title,200)&&text(e.quote,100000)&&text(e.text,e.kind==='audio'?10000:100000)&&(e.kind!=='audio'||(e.text.trim().length>0&&e.quote===''))&&labels(e.tags)&&labels(e.characters)&&text(e.color,40)
    &&['app-reader','app-audio','obsidian'].includes(e.origin)&&typeof e.updatedAt==='string'&&/^\d{4}-\d\d-\d\dT.*Z$/.test(e.updatedAt)&&Number.isFinite(Date.parse(e.updatedAt))&&typeof e.deleted==='boolean';
}
export function validNoteOperation(v:unknown):v is NoteOperation {
  const op=v as NoteOperation;
  return !!op&&validId(op.operationId)&&Number.isSafeInteger(op.baseRevision)&&op.baseRevision>=0&&op.baseRevision<Number.MAX_SAFE_INTEGER&&validNote(op.entry);
}
