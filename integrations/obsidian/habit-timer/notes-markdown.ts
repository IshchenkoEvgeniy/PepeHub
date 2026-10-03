import {validNote,type NoteEntry} from './notes.ts';
import {equalValue} from './metadata.ts';
const pattern=/<!-- pepehub-note:([0-9a-f-]+):([A-Za-z0-9+/=]+) -->\r?\n([\s\S]*?)\r?\n<!-- \/pepehub-note:\1 -->/gi;
const encode=(entry:NoteEntry)=>{
  const bytes=new TextEncoder().encode(JSON.stringify(entry));let result='';
  for(let at=0;at<bytes.length;at+=8192)result+=String.fromCharCode(...bytes.subarray(at,at+8192));
  return btoa(result);
};
const decode=(s:string):NoteEntry=>{const v:unknown=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0))));if(!validNote(v))throw new Error('Invalid PepeHub note marker; original text was preserved.');return v;};
const safe=(s:string)=>s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/`/g,'&#96;');
const uns=(s:string)=>s.replace(/&#96;/g,'`').replace(/&lt;/g,'<').replace(/&amp;/g,'&');
function display(e:NoteEntry):string {
  if(e.kind==='markdown')return e.text;
  return `### ${e.title || (e.kind==='audio'?'Аудиозаметка':'Заметка')}\n<!-- quote -->\n${safe(e.quote)}\n<!-- /quote -->\n<!-- text -->\n${safe(e.text)}\n<!-- /text -->\nТеги: ${e.tags.join(', ')}\nПерсонажи: ${e.characters.join(', ')}\nЦвет: ${e.color}`;
}
export function noteBlock(e:NoteEntry):string {return `<!-- pepehub-note:${e.id}:${encode(e)} -->\n${display(e)}\n<!-- /pepehub-note:${e.id} -->`;}
function visible(old:NoteEntry,body:string):NoteEntry {
  if(body===display(old))return old;
  let next:NoteEntry;
  if(old.kind==='markdown')next={...old,text:body};
  else {
    const quote=body.match(/<!-- quote -->\n([\s\S]*?)\n<!-- \/quote -->/),text=body.match(/<!-- text -->\n([\s\S]*?)\n<!-- \/text -->/);
    if(!quote||!text)throw new Error('PepeHub: разделители заметки изменены. Восстановите комментарии HTML в этой заметке.');
    const labels=(name:string,previous:string[])=>{const value=body.match(new RegExp(`^${name}: (.*)$`,'m'))?.[1];if(value===undefined) return previous;return value===previous.join(', ')?previous:value.split(/[,;]+/).map(s=>s.trim()).filter(Boolean);};
    next={...old,title:body.match(/^### (.*)/)?.[1] ?? old.title,quote:uns(quote[1]!),text:uns(text[1]!),tags:labels('Теги',old.tags),characters:labels('Персонажи',old.characters),color:body.match(/^Цвет: (.*)$/m)?.[1] ?? old.color};
  }
  if(equalValue(next,old))return old;
  next.updatedAt=new Date().toISOString();
  if(!validNote(next))throw new Error('PepeHub: заметка превышает допустимый размер; текст сохранён в Obsidian.');
  return next;
}
const journal=/^#{2,4}\s+(?:(?:📖|🎧)\s*)?(?:Progress|Журнал\s+(?:чтения|прослушивания))\s*$/i;
/** Preserve frontmatter, journal sections and native Markdown exactly in place. */
export function readNoteMarkdown(content:string,itemId:string,mediaType:NoteEntry['mediaType'],assign=true):{content:string;entries:NoteEntry[]} {
  const entries:NoteEntry[]=[],used=new Set<string>();
  let transformed=content.replace(pattern,(whole:string,id:string,data:string,body:string)=>{
    let old=decode(data);if(old.id!==id)throw new Error('PepeHub: inconsistent note identity');
    let e=visible(old,body);
    if(old.itemId!==itemId||used.has(e.id)){if(!assign)return whole;e={...e,id:crypto.randomUUID(),itemId,mediaType};}
    used.add(e.id);entries.push(e);
    return assign&&(!equalValue(e,old))?noteBlock(e):whole;
  });
  // Unmatched sync delimiters must never be interpreted as deletion or native text.
  const stripped=transformed.replace(pattern,'');
  if(stripped.includes('<!-- pepehub-note:')||stripped.includes('<!-- /pepehub-note:'))throw new Error('PepeHub: повреждён блок заметки; исходный текст сохранён.');
  if(!assign)return {content:transformed,entries};
  let prefix='';
  if(transformed.startsWith('---\n')||transformed.startsWith('---\r\n')){
    const match=transformed.match(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/);if(match){prefix=match[0];transformed=transformed.slice(prefix.length);}
  }
  const blocks=Array.from(transformed.matchAll(pattern));
  let result='',at=0;
  function capture(segment:string):string {
    let journalSection=false,group='';const parts:string[]=[];
    const flush=()=>{
      if(!group)return;
      if(group.trim().replace(/^[-*#\s]+$/,'').length===0||group.length>100000)parts.push(group);
      else {const e:NoteEntry={id:crypto.randomUUID(),itemId,mediaType,kind:'markdown',title:'Заметки Obsidian',quote:'',text:group,tags:[],characters:[],color:'yellow',anchor:{},origin:'obsidian',updatedAt:new Date().toISOString(),deleted:false};entries.push(e);parts.push(noteBlock(e)+'\n');}
      group='';
    };
    for(const line of segment.match(/[^\n]*\n|[^\n]+$/g) ?? []) {
      if(journal.test(line.trim())){flush();journalSection=true;}
      else if(/^#{1,6}\s/.test(line)){journalSection=false;}
      if(journalSection){flush();parts.push(line);}else group+=line;
    }
    flush();return parts.join('');
  }
  for(const block of blocks){result+=capture(transformed.slice(at,block.index));result+=block[0];at=block.index!+block[0].length;}
  result+=capture(transformed.slice(at));
  return {content:prefix+result,entries};
}
export function applyNoteMarkdown(content:string,entry:NoteEntry,baseline:NoteEntry|null):{content:string;applied:boolean} {
  const current=readNoteMarkdown(content,entry.itemId,entry.mediaType,false).entries.find(e=>e.id===entry.id) ?? null;
  if(equalValue(current,entry.deleted?null:entry))return {content,applied:true};
  if(!equalValue(current,baseline?.deleted?null:baseline))return {content,applied:false};
  let found=false;
  const result=content.replace(pattern,(whole:string,id:string)=>{if(id!==entry.id)return whole;found=true;return entry.deleted?'':noteBlock(entry);});
  if(found||entry.deleted)return {content:result,applied:true};
  return {content:`${content}\n${noteBlock(entry)}\n`,applied:true};
}
