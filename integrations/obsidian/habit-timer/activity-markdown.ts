import { validActivity, type ActivityEntry } from './activity.ts';
import { equalValue } from './metadata.ts';
const heading = /^#{2,4}\s+(?:(?:📖|🎧)\s*)?(?:Progress|Журнал\s+(?:чтения|прослушивания))\s*$/i;
const anyHeading = /^#{1,6}\s/;
const marker = /<!-- pepehub-activity:([0-9a-f-]+):([A-Za-z0-9+/=]+) -->\s*$/i;
const encode = (entry: ActivityEntry) => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(entry))));
const decode = (s:string):ActivityEntry|null => {try {const v:unknown=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(s),c=>c.charCodeAt(0))));return validActivity(v)?v:null;}catch{return null;}};
const clean = (s:string) => s.replace(/\r?\n/g,' ').replace(/\\/g,'\\\\').replace(/\|/g,'\\|');
export function activityDuration(s:string):number|null {
  const colon=s.trim().match(/^(\d+):(\d{2}):(\d{2})$/);
  if (colon) return Number(colon[1])*3600000+Number(colon[2])*60000+Number(colon[3])*1000;
  const short=s.trim().match(/^(\d+):(\d{2})$/);
  if (short) return Number(short[1])*60000+Number(short[2])*1000;
  if (/^(?:-|0|)$/.test(s.trim())) return 0;
  return null;
}
export function activityRow(e:ActivityEntry):string {
  const seconds=Math.round(e.durationMs/1000), hours=Math.floor(seconds/3600), minutes=Math.floor(seconds/60)%60;
  const time=`${String(hours).padStart(2,'0')}:${String(minutes).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')}`;
  const label=e.unit==='characters'?'симв.':e.unit==='minutes'?'мин.':e.unit==='pages'?'стр.':'';
  return `| ${e.day} | ${time} | ${e.unit==='characters'?'симв.: ':''}${Number(e.progress.toFixed(3))} | ${label||'-'} | ${clean(e.note)||'-'} | <!-- pepehub-activity:${e.id}:${encode(e)} -->`;
}
function columns(line:string):string[] {
  // Split only actual separators; an escaped pipe belongs to a note.
  const cells:string[]=[];let cell='',escaped=false;
  for(const ch of line){if(ch==='|'&&!escaped){cells.push(cell.trim());cell='';}else{cell+=ch;} if(ch==='\\')escaped=!escaped;else escaped=false;}
  cells.push(cell.trim());return cells;
}
function parse(line:string,itemId:string,mediaType:ActivityEntry['mediaType'],assign:boolean):ActivityEntry|null {
  const match=line.match(marker), decoded=match?decode(match[2]!):null, old=decoded?.id===match?.[1]?decoded:null, cells=columns(line.replace(marker,''));
  if(match && !old)throw new Error('PepeHub: повреждён маркер журнала; исходная строка сохранена.');
  if(cells.length<6 || !/^\d{4}-\d\d-\d\d$/.test(cells[1]||''))return null;
  const duration=activityDuration(cells[2]||'');if(duration===null)return null;
  const progress=Number((cells[3]||'').replace(/^симв\.:\s*/,'').match(/^\d+(?:\.\d+)?/)?.[0]||0);
  if (!old && !assign) return null;
  const exactDuration=old && Math.round(old.durationMs/1000)*1000===duration?old.durationMs:duration;
  const exactProgress=old && Number(old.progress.toFixed(3))===progress?old.progress:progress;
  const entry:ActivityEntry={id:old?.itemId===itemId?old.id:crypto.randomUUID(),itemId,mediaType,day:cells[1]!,durationMs:exactDuration,progress:exactProgress,
    unit:old?.unit ?? (mediaType==='audiobook'?'minutes':'pages'),mediaMs:old && exactProgress===old.progress?old.mediaMs:(mediaType==='audiobook'?Math.round(exactProgress*60000):0),
    startedAt:old?.startedAt ?? null,endedAt:old?.endedAt ?? null,offsetMinutes:old?.offsetMinutes ?? null,
    note:old && (clean(old.note)||'-')===(cells[5]||'') ? old.note : ((cells[5]||'')==='-'?'':(cells[5]||'').replace(/\\([\\|])/g,'$1')),origin:old?.origin ?? 'obsidian',deleted:false};
  return validActivity(entry)?entry:null;
}
/** Annotates old rows in place; equal/duplicate rows each retain their own UUID. */
export function readActivityMarkdown(content:string,itemId:string,mediaType:ActivityEntry['mediaType'],assign=true):{content:string;entries:ActivityEntry[]} {
  let inside=false,inNote=false;const entries:ActivityEntry[]=[],used=new Set<string>();
  const lines=content.split(/\r?\n/).map(line=>{
    if(line.trim().startsWith('<!-- pepehub-note:')){inNote=true;return line;}
    if(line.trim().startsWith('<!-- /pepehub-note:')){inNote=false;return line;}
    if(inNote)return line;
    if(heading.test(line.trim())){inside=true;return line;}
    if(anyHeading.test(line.trim()))inside=false;
    // A present marker is evidence that the row still exists. Never interpret
    // malformed or displaced rows as deletion of the last synced entry.
    const marked=/<!--\s*pepehub-activity:/i.test(line);
    if(marked && (!inside || !line.trim().startsWith('|') || !marker.test(line)))throw new Error('PepeHub: повреждена строка журнала; проверьте раздел Progress и маркер.');
    if(!inside||!line.trim().startsWith('|'))return line;
    let e=parse(line,itemId,mediaType,assign);
    if(!e){if(marked)throw new Error('PepeHub: некорректная дата или время строки журнала; исходная строка сохранена.');return line;}
    if(used.has(e.id)){if(!assign)return line;e={...e,id:crypto.randomUUID()};}
    used.add(e.id);entries.push(e);
    // Do not normalize the visible cells of existing user rows.
    return assign ? `${line.replace(marker,'').trimEnd()} <!-- pepehub-activity:${e.id}:${encode(e)} -->` : line;
  });
  return {content:lines.join(content.includes('\r\n')?'\r\n':'\n'),entries};
}
function accountTime(content:string,deltaMs:number,itemId:string,mediaType:ActivityEntry['mediaType']):string {
  const newline=content.includes('\r\n')?'\r\n':'\n', prefix=`---${newline}`;
  if(!deltaMs||!content.startsWith(prefix))return content;
  const end=content.indexOf(`${newline}---`,prefix.length);if(end<0)return content;
  const fm=content.slice(prefix.length,end),pattern=/^(?:["']?)(Reading time|Time spent)(?:["']?):\s*([^\r\n]*)\r?$/m,match=fm.match(pattern);
  let before=match?activityDuration(match[2]!.replace(/^["']|["']$/g,'')):0;
  if(/^pepehub_time_from_journal:\s*true\s*$/m.test(fm))before=readActivityMarkdown(content,itemId,mediaType,false).entries.reduce((sum,e)=>sum+e.durationMs,0);
  if(before===null)return content; // Preserve non-duration custom values.
  const seconds=Math.max(0,Math.round((before+deltaMs)/1000));
  const value=`${String(Math.floor(seconds/3600)).padStart(2,'0')}:${String(Math.floor(seconds/60)%60).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')}`;
  const next=match?fm.replace(pattern,`${match[1]}: "${value}"`):`${fm}${newline}Reading time: "${value}"`;
  return `${prefix}${next}${content.slice(end)}`;
}
/** CAS against the last observed row; vault.process supplies the current contents. */
export function applyActivityMarkdown(content:string,entry:ActivityEntry,baseline:ActivityEntry|null):{content:string;applied:boolean} {
  const current=readActivityMarkdown(content,entry.itemId,entry.mediaType,false).entries.find(e=>e.id===entry.id) ?? null;
  if (equalValue(current,entry.deleted?null:entry)) return {content,applied:true};
  if (!equalValue(current,baseline?.deleted?null:baseline)) return {content,applied:false};
  const accounted=accountTime(content,(entry.deleted?0:entry.durationMs)-(current?.durationMs || 0),entry.itemId,entry.mediaType);
  const newline=content.includes('\r\n')?'\r\n':'\n';
  const lines=accounted.split(/\r?\n/), index=lines.findIndex(line=>line.match(marker)?.[1]===entry.id);
  if(index>=0){if(entry.deleted)lines.splice(index,1);else lines[index]=activityRow(entry);return {content:lines.join(newline),applied:true};}
  if(entry.deleted)return {content,applied:true};
  let inNote=false;
  const start=lines.findIndex(line=>{if(line.trim().startsWith('<!-- pepehub-note:')){inNote=true;return false;}if(line.trim().startsWith('<!-- /pepehub-note:')){inNote=false;return false;}return !inNote&&heading.test(line.trim());});
  if(start<0)return {content:`${accounted.trimEnd()}${newline}${newline}### 📖 Progress${newline}| Date | Time | Progress | % | Notes |${newline}|---|---|---|---|---|${newline}${activityRow(entry)}${newline}`,applied:true};
  let at=start+1;while(at<lines.length&&!anyHeading.test(lines[at]!.trim()))at++;
  lines.splice(at,0,activityRow(entry));return {content:lines.join(newline),applied:true};
}
