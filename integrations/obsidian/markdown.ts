import type {Book,Entity,Session} from '../../contracts/protocol.ts';
function cell(value: string): string {
  return value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('|','&#124;').replace(/[\r\n]/g,' ').replace(/([\\`*_[\]])/g,'\\$1');
}
/** Pure transformation, suitable for Vault.process(). Never writes to a vault itself. */
export function updateBookBlock(existing: string,book: Entity,sessions: Entity[]): string {
  if(book.entityType!=='book'||book.deleted||!book.payload) throw new Error('Live book required');
  const b=book.payload as Book;
  const eol=existing.includes('\r\n')?'\r\n':'\n';
  const start=`<!-- pepehub:${book.entityId}:start -->`,end=`<!-- pepehub:${book.entityId}:end -->`;
  const lines=[start,`## ${cell(b.title)}`,'',`Авторы: ${b.authors.map(cell).join(', ') || '—'}`,`Формат: ${b.format === 'audio' ? 'Аудиокнига' : b.format.toUpperCase()}`,`Статус: ${{planned:'В планах',active:'В процессе',finished:'Завершено'}[b.status]}`,'','### Сессии','','| Начало (UTC) | Активность | Минуты | ID |','| --- | --- | ---: | --- |'];
  const unique=new Map<string,Entity>();
  for(const entity of sessions) if(entity.entityType==='session'&&!entity.deleted&&entity.payload&&(entity.payload as Session).bookId===book.entityId) {
    const previous=unique.get(entity.entityId);
    if(!previous||previous.revision<entity.revision) unique.set(entity.entityId,entity);
  }
  for(const entity of [...unique.values()].sort((a,b)=>(a.payload as Session).startedAt.localeCompare((b.payload as Session).startedAt)||a.entityId.localeCompare(b.entityId))) {
    const s=entity.payload as Session;
    lines.push(`| ${cell(s.startedAt)} | ${s.kind==='reading'?'Чтение':'Прослушивание'} | ${(s.activeSeconds/60).toFixed(1)} | ${entity.entityId} |`);
  }
  lines.push(end);
  const block=lines.join(eol);
  const a=existing.indexOf(start),z=existing.indexOf(end);
  if(a<0&&z<0) return existing+(existing.endsWith(eol+eol)||existing.length===0?'':existing.endsWith(eol)?eol:eol+eol)+block+eol;
  if(a<0||z<a||existing.indexOf(start,a+start.length)>=0||existing.indexOf(end,z+end.length)>=0) throw new Error('Ambiguous managed block; manual resolution required');
  return existing.slice(0,a)+block+existing.slice(z+end.length);
}
