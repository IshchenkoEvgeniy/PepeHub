/* Isolated design prototype. No database, filesystem, playback or network access. */
const $ = (s, root = document) => root.querySelector(s);
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
  library:'M3 3h6l3 3 3-3h6v16h-6l-3 2-3-2H3zM12 6v15M6 7h3M15 7h3',
  book:'M5 3h13v18H5a2 2 0 0 1 0-4h13M5 3a2 2 0 0 0-2 2v14M8 7h6M8 10h6',
  audio:'M3 14v-3a9 9 0 0 1 18 0v3M3 12h4v8H3zM17 12h4v8h-4z',
  media:'M4 5h16v14H4zM10 9l5 3-5 3z',star:'m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9z',
  stats:'M4 20V10M10 20V4M16 20v-8M22 20H2',quote:'M4 5h6v7H5c0 4 2 5 5 6M14 5h6v7h-5c0 4 2 5 5 6',
  settings:'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1zM15 12a3 3 0 1 0-6 0 3 3 0 0 0 6 0',
  search:'m16 16 5 5M18 10a8 8 0 1 0-16 0 8 8 0 0 0 16 0',plus:'M12 5v14M5 12h14',arrow:'M5 12h14m-5-5 5 5-5 5',
  close:'m6 6 12 12M6 18 18 6',menu:'M4 6h16M4 12h16M4 18h16',back:'M19 12H5m5-5-5 5 5 5',
  more:'M12 5h.01M12 12h.01M12 19h.01',play:'m8 4 12 8-12 8z',check:'m5 12 4 4L19 6',folder:'M3 6h7l2 3h9v11H3z',
  pencil:'m15 4 5 5M4 20l5-1L21 7l-5-5L4 14z',note:'M5 3h14v18H5zM8 8h8M8 12h8M8 16h5',clock:'M12 7v5l4 2M22 12a10 10 0 1 0-20 0 10 10 0 0 0 20 0'
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true"><path d="${paths[name] || paths.book}"/></svg>`;
const navItems = [['library','library','Библиотека'],['quotes','quote','Цитаты и заметки'],['books','book','Книги'],['audio','audio','Аудиокниги'],['media','media','Медиа'],['recommendations','star','Рекомендации'],['statistics','stats','Статистика']];
const labels = {finished:'Завершено',paused:'Отложено',abandoned:'Брошено',active:'В процессе',planned:'В планах'};
const titles = [
  ['Архитектура привычек','Елена Соколова','finished','book','green',5,320,8],
  ['Атлас тишины','Михаил Лесной','finished','audio','sand',4,286,5],
  ['Город у моря','Илья Северин','finished','book','blue',5,248,6],
  ['Дорога к маяку','Алексей Мирный','paused','audio','dark',null,364,2],
  ['Завтра начинается сегодня','Мария Орлова','finished','book','light',4,212,4],
  ['Северный ветер','Анна Волкова','abandoned','book','blue',null,416,1],
  ['Письма из сада','Вера Липова','finished','audio','green',5,180,3],
  ['Время собирать камни','Павел Речной','paused','book','red',null,308,2],
  ['На другой стороне','Ольга Белова','finished','book','dark',4,352,5],
  ['Свет в окне','Андрей Кленов','finished','audio','light',4,240,4],
  ['Медленные дни','Нина Тихая','paused','book','sand',null,196,3],
  ['Там, где начинается лес','Софья Ветрова','finished','audio','green',5,288,6]
];
const base = titles.map((b,i) => ({id:i+1,title:b[0],author:b[1],status:b[2],kind:b[3],palette:b[4],rating:b[5],pages:b[6],quotes:b[7],date:`${31-i*2} ${['октября','сентября','августа','июля','июля','июня','июня','мая','апреля','марта','февраля','января'][i]}`,day:31-i*2,month:[10,9,8,7,7,6,6,5,4,3,2,1][i],year:2026,minutes:260+i*35,impression:i===0?'Спокойная и практичная книга. Хочется возвращаться к главам о маленьких ежедневных действиях.':'Сохранить мысли после чтения. Что хочется взять с собой?',quote:i===0?'«То, что мы повторяем каждый день, постепенно становится нашей жизнью.»':'«Иногда достаточно остановиться, чтобы заметить самое важное.»'}));
const files = [...base.slice(0,5).map((b,i)=>({...b,id:100+i,kind:'book',status:i===0?'active':i===4?'finished':'planned',progress:i===0?31:i===4?100:0})),{...base[5],id:105,kind:'book',status:'active',progress:24}];
const audioFiles = base.filter(b=>b.kind==='audio').map((b,i)=>({...b,id:200+i,status:i===0?'active':'planned',progress:i===0?42:0}));
const monthNames = ['Янв','Фев','Мар','Апр','Май','Июн','Июл','Авг','Сен','Окт'];
let activity = Array(10).fill(0);
let state = {page:'library',filter:'all',kind:'all',query:'',sort:'recent',selected:1,scenario:'normal',fileFilter:'all',mobileDetail:false,detailTab:'impression'};
let archive = base.slice();
let visibleRows = [];
let toastTimer;
const coverCache = new Map();
function cover(book, className='') {
  const key = `${book.title}|${book.palette}`;
  if(!coverCache.has(key)) {
    const colors={green:['#29473d','#d4dbc2'],blue:['#263c47','#ccd6d7'],red:['#553b32','#e6d7bd'],sand:['#59513c','#e2dcc6'],dark:['#282823','#cecfb8'],light:['#c2c1aa','#292e25']};
    const [bg,ink]=colors[book.palette] || colors.green;
    let lines=[],line='';
    book.title.split(' ').forEach(word=>{if((line+' '+word).trim().length>14){lines.push(line);line=word}else line=(line+' '+word).trim()});lines.push(line);
    const art = book.palette==='blue'?'<path d="M0 222q50-44 100 0t100 0v78H0z"/><path d="M0 248q50-44 100 0t100 0v52H0z"/>':book.palette==='green'?'<path d="M100 291V159m0 73c-37-3-51-25-44-48 28 6 44 23 44 48zm0-31c30-5 45-25 40-46-29 7-40 25-40 46z"/>':book.palette==='dark'?'<path d="m90 270 5-83h10l5 83M85 187h30l-15-20zM70 274h60M100 160v-20M60 175l-26-7M140 175l26-7"/>':book.palette==='sand'?'<circle cx="100" cy="218" r="42"/><path d="M100 180v39l23 13M50 271h100"/>':book.palette==='light'?'<path d="M50 266V158h100v108M100 158v108M50 212h100"/>':'<path d="M40 267q60-60 120 0M40 247q60-60 120 0M40 227q60-60 120 0"/>';
    const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="200" height="300" viewBox="0 0 200 300"><rect width="200" height="300" fill="${bg}"/><rect x="8" width="3" height="300" fill="${ink}" opacity=".18"/><text x="24" y="30" fill="${ink}" font-family="Georgia,serif" font-size="10">${esc(book.author)}</text><g fill="none" stroke="${ink}" stroke-width="1.2" opacity=".5">${art}</g><text fill="${ink}" font-family="Georgia,serif" font-size="22">${lines.map((l,i)=>`<tspan x="24" y="${69+i*29}">${esc(l)}</tspan>`).join('')}</text><text x="24" y="284" fill="${ink}" font-size="8" font-family="sans-serif">PepeHub · концептуальная обложка</text></svg>`;
    coverCache.set(key,`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`);
  }
  return `<img class="cover ${className}" src="${coverCache.get(key)}" alt="Обложка: ${esc(book.title)}" loading="lazy" width="200" height="300">`;
}
const n = v => new Intl.NumberFormat('ru-RU').format(v);
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,3500)}
function heading(title,sub,action=''){return `<div class="heading"><div><h1>${title}</h1><p>${sub}</p></div>${action}</div>`}
function primary(text,action,extra=''){return `<button class="button primary" data-action="${action}" ${extra}>${icon('plus')}${text}</button>`}
function statusMark(b){return `<span class="row-state"><span class="state-dot ${b.status}"></span>${labels[b.status]}</span>`}
function format(b){return `<span class="format-label">${icon(b.kind==='audio'?'audio':'book')}${b.kind==='audio'?'Аудиокнига':'Книга'}</span>`}
function renderNav(){
  document.body.dataset.page=state.page;
  $('#nav').innerHTML=navItems.map(([id,ic,label],i)=>`${i===2?'<div class="nav-group">Файлы и воспроизведение</div>':i===5?'<div class="nav-group">Открывать и замечать</div>':''}<a class="nav-button" href="#${id}" ${state.page===id?'aria-current="page"':''}>${icon(ic)}${label}</a>`).join('');
  $('#crumb').textContent=navItems.find(i=>i[0]===state.page)?.[2] || 'Библиотека';
}
function data(){return state.scenario==='empty'?[]:archive}
function filtered(){return data().filter(b=>(state.filter==='all'||b.status===state.filter)&&(state.kind==='all'||b.kind===state.kind)&&`${b.title} ${b.author}`.toLocaleLowerCase('ru').includes(state.query.toLocaleLowerCase('ru'))).sort((a,b)=>state.sort==='title'?a.title.localeCompare(b.title,'ru'):a.id-b.id)}
function counts(){return ['all','finished','paused','abandoned'].map(k=>({key:k,label:k==='all'?'Все':labels[k],count:data().filter(b=>k==='all'||b.status===k).length}))}
function library(){
  $('#main').innerHTML=heading('Библиотека','Ваши книги, впечатления и то, что осталось с вами.',primary('Добавить запись','add'))+
  `<div class="summary-filters" aria-label="Статус произведения">${counts().map(c=>`<button class="summary-filter" data-filter="${c.key}" aria-pressed="${state.filter===c.key}"><span>${c.label}</span><strong>${n(c.count)}</strong></button>`).join('')}</div>
  <div class="archive-layout ${state.mobileDetail?'mobile-detail':''}"><section class="catalog" aria-label="Произведения"><div class="toolbar"><label class="search">${icon('search')}<input id="search" type="search" aria-label="Найти по названию или автору" placeholder="Название или автор" value="${esc(state.query)}"></label><select id="kind" aria-label="Формат"><option value="all">Все форматы</option><option value="book">Книги</option><option value="audio">Аудиокниги</option></select><select id="sort" aria-label="Сортировка"><option value="recent">Недавние</option><option value="title">По названию</option></select></div><div class="list-caption"><span id="result-count" aria-live="polite"></span><span>Личный архив</span></div><div class="column-head"><span>Произведение</span><span>Статус</span><span>Завершение</span></div><div class="list-viewport" id="list" role="region" aria-label="Список произведений" tabindex="0"></div></section><aside class="detail" id="detail" aria-label="Карточка произведения"></aside></div>
`;
  $('#kind').value=state.kind;$('#sort').value=state.sort;
  $('#search').addEventListener('input',e=>{state.query=e.target.value;updateList();renderDetail()});
  $('#kind').addEventListener('change',e=>{state.kind=e.target.value;updateList();renderDetail()});
  $('#sort').addEventListener('change',e=>{state.sort=e.target.value;updateList();renderDetail()});
  updateList();renderDetail();
}
function updateList(){
  const list=$('#list');visibleRows=filtered();if(visibleRows.length&&!visibleRows.some(b=>b.id===state.selected))state.selected=visibleRows[0].id;$('#result-count').textContent=`${n(visibleRows.length)} произведений`;
  list.scrollTop=0;
  if(state.scenario==='loading'){list.innerHTML=Array.from({length:5},()=>'<div class="skeleton-row" aria-hidden="true"><div class="skeleton-cover"></div><div class="skeleton-lines"><span></span><span></span></div></div>').join('');list.setAttribute('aria-busy','true');list.onkeydown=null;return}
  list.removeAttribute('aria-busy');
  if(state.scenario==='error'){list.innerHTML='<div class="empty-state" role="alert"><h2>Архив не загрузился</h2><p>Не удалось прочитать записи. Попробуйте ещё раз.</p><button class="button secondary" data-action="retry">Повторить</button></div>';return}
  if(!visibleRows.length){list.innerHTML=`<div class="empty-state"><h2>${data().length?'Ничего не найдено':'История начинается с одной книги'}</h2><p>${data().length?'Попробуйте другое название или сбросьте фильтры.':'Добавьте прочитанное, отложенное или брошенное произведение.'}</p><button class="button secondary" data-action="${data().length?'reset':'add'}">${data().length?'Сбросить фильтры':'Добавить запись'}</button></div>`;return}
  /* Virtual window: only visible metadata rows + 2-row overscan; no tracks or text indexes. */
  list.innerHTML=`<div id="row-space" style="height:${visibleRows.length*100}px;position:relative"><div id="row-window" style="position:absolute;left:0;right:0;top:0"></div></div>`;
  list.onscroll=paintRows;paintRows();
  list.onkeydown=e=>{if(!['ArrowDown','ArrowUp'].includes(e.key))return;e.preventDefault();const index=Math.max(0,visibleRows.findIndex(b=>b.id===state.selected));const next=Math.max(0,Math.min(visibleRows.length-1,index+(e.key==='ArrowDown'?1:-1)));state.selected=visibleRows[next].id;list.scrollTop=Math.max(0,next*100-100);paintRows();renderDetail();list.focus({preventScroll:true})};
}
function paintRows(){const list=$('#list'),win=$('#row-window');if(!win)return;const start=Math.max(0,Math.floor(list.scrollTop/100)-2),end=Math.min(visibleRows.length,start+Math.ceil(list.clientHeight/100)+5);win.style.transform=`translateY(${start*100}px)`;win.innerHTML=visibleRows.slice(start,end).map(b=>`<button class="book-row ${state.selected===b.id?'selected':''}" data-book="${b.id}" aria-pressed="${state.selected===b.id}" aria-label="${esc(b.title)}, ${esc(b.author)}, ${labels[b.status]}">${cover(b)}<span><span class="book-name">${esc(b.title)}</span><span class="book-author">${esc(b.author)}</span>${format(b)}</span>${statusMark(b)}<span class="row-date">${b.status==='finished'?b.date:'—'}<small>${b.rating?`${b.rating} из 5`:'Без оценки'}</small></span></button>`).join('')}
function renderDetail(){
  const el=$('#detail');if(!el)return;
  const b=visibleRows.find(b=>b.id===state.selected)||visibleRows[0];
  if(!b||['loading','error'].includes(state.scenario)){
    el.innerHTML='<h2>Ваша история</h2><p class="author">Выберите произведение, чтобы вернуться к своим впечатлениям и цитатам.</p>';return;
  }
  const volume=b.kind==='audio'?Math.floor(b.minutes/60)+' ч '+b.minutes%60+' мин':b.pages+' страниц';
  const tab=state.detailTab||'impression';
  el.innerHTML='<button class="text-button mobile-back" data-action="back-list">'+icon('back')+'К списку</button>'+
    '<div class="detail-top"><span>Ваша запись</span><button class="icon-button" data-action="edit" data-id="'+b.id+'" aria-label="Редактировать запись">'+icon('pencil')+'</button></div>'+
    '<div class="record-header">'+cover(b)+'<div><h2>'+esc(b.title)+'</h2><p class="author">'+esc(b.author)+'</p><p class="record-format">'+(b.kind==='audio'?'Аудиокнига':'Книга')+' · '+volume+'</p></div></div>'+
    '<div class="detail-status">'+statusMark(b)+'<span class="rating" aria-label="Оценка '+(b.rating||'не задана')+'">'+(b.rating?icon('star')+' '+b.rating+' / 5':'Без оценки')+'</span></div>'+
    '<dl class="record-facts"><div><dt>Завершение</dt><dd>'+(b.status==='finished'?b.date:'—')+'</dd></div><div><dt>Сохранено цитат</dt><dd>'+b.quotes+'</dd></div></dl>'+
    '<div class="record-tabs" role="tablist" aria-label="Память о произведении"><button id="impression-tab" role="tab" aria-controls="record-content" aria-selected="'+(tab==='impression')+'" data-detail-tab="impression">Впечатления</button><button id="quotes-tab" role="tab" aria-controls="record-content" aria-selected="'+(tab==='quotes')+'" data-detail-tab="quotes">Цитаты <span>'+b.quotes+'</span></button></div>'+
    '<section id="record-content" class="detail-section" role="tabpanel" aria-labelledby="'+(tab==='impression'?'impression-tab':'quotes-tab')+'">'+
      (tab==='impression'?'<h3>После чтения</h3><p>'+esc(b.impression)+'</p><button class="text-button" data-action="edit" data-id="'+b.id+'">'+icon('pencil')+'Дополнить впечатление</button>':'<h3>Из сохранённого</h3><blockquote>'+esc(b.quote)+'</blockquote><a class="text-button" href="#quotes">Открыть все цитаты '+icon('arrow')+'</a>')+
    '</section><div class="record-footnote">'+icon('library')+'Личная история в PepeHub</div>';
}
function fileScreen(audio=false){
  const rows=(audio?audioFiles:files).filter(b=>state.fileFilter==='all'||b.status===state.fileFilter);const current=(audio?audioFiles:files)[0];
  $('#main').innerHTML=heading(audio?'Аудиокниги':'Книги',audio?'Голоса и истории, к которым хочется вернуться.':'Файлы, планы и время для следующей главы.',primary('Добавить файлы','import'))+
  `<div class="feature-book">${cover(current)}<div><span class="caption">${audio?'Продолжить слушать':'Сейчас читаю'}</span><h2>${esc(current.title)}</h2><p class="muted">${esc(current.author)}</p><button class="button primary" data-action="${audio?'listen':'read'}">${icon(audio?'play':'book')}${audio?'Продолжить':'Читать дальше'}</button></div><div class="feature-progress"><strong class="num">${current.progress}%</strong><div><div class="progress-label"><span>${audio?'Глава 7 из 16':'Глава 6 из 19'}</span></div><div class="progress"><span style="width:${current.progress}%"></span></div><small class="muted">${audio?'Осталось 3 ч 24 мин':'99 из 320 страниц'}</small></div></div></div>
  <div class="tab-row" aria-label="Статус файла">${[['all','Все файлы'],['active',audio?'Слушаю':'Читаю'],['planned','В планах'],['finished','Завершено']].map(([k,l])=>`<button data-file-filter="${k}" aria-pressed="${state.fileFilter===k}">${l} <span class="muted">${(audio?audioFiles:files).filter(b=>k==='all'||b.status===k).length}</span></button>`).join('')}</div><div class="section-title"><h2>${state.fileFilter==='planned'?'Следующие истории':'На вашем устройстве'}</h2><button class="text-button" data-action="import">${icon('folder')}Подключить папку</button></div><div class="shelf" style="--shelf-count:${Math.min(6,Math.max(1,rows.length))}">${rows.map(b=>`<button class="shelf-item" data-file="${b.id}">${cover(b)}<span class="book-name">${esc(b.title)}</span><span class="book-author">${esc(b.author)}</span><span class="format-label">${labels[b.status]} · ${audio?'M4B':'EPUB'}</span></button>`).join('')||'<div class="empty-state"><h2>Пока нет завершённых файлов</h2><p>Продолжите историю, когда будет настроение.</p></div>'}</div>`;
}
function chart(type){const W=480,H=210,L=32,R=12,T=18,B=28,iw=W-L-R,ih=H-T-B,max=Math.max(3,Math.ceil((type==='bars'?Math.max(...activity):activity.reduce((a,b)=>a+b,0))/3)*3);let sum=0;const vals=activity.map(v=>type==='bars'?v:sum+=v);return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${type==='bars'?'Завершено по месяцам: '+activity.join(', '):'Накопленный итог за 10 месяцев: '+vals.join(', ')}">${[0,1,2,3].map(i=>{const y=T+ih-i*ih/3;return `<line class="grid" x1="${L}" y1="${y}" x2="${W-R}" y2="${y}"/><text x="${L-8}" y="${y+4}" text-anchor="end">${max*i/3}</text>`}).join('')}${type==='bars'?vals.map((v,i)=>`<rect class="mark" x="${L+i*iw/10+8}" y="${T+ih-v/max*ih}" width="${iw/10-16}" height="${v/max*ih}"><title>${monthNames[i]}: ${v} завершено</title></rect>`).join(''):`<polyline class="line" points="${vals.map((v,i)=>`${L+i*iw/9},${T+ih-v/max*ih}`).join(' ')}"/>`}${monthNames.filter((_,i)=>i%3===0).map((m,j)=>`<text x="${type==='bars'?L+(j*3+.5)*iw/10:L+j*3*iw/9}" y="${H-5}" text-anchor="middle">${m}</text>`).join('')}</svg>`}
function statistics(){const done=data().filter(b=>b.status==='finished');activity=Array.from({length:10},(_,i)=>done.filter(b=>b.month===i+1).length);const total=done.length;const bookCount=done.filter(b=>b.kind==='book').length;const audioCount=done.length-bookCount;const reading=Math.round(done.filter(b=>b.kind==='book').reduce((s,b)=>s+b.minutes,0)/60),audio=Math.round(done.filter(b=>b.kind==='audio').reduce((s,b)=>s+b.minutes,0)/60);const goal=state.scenario==='large'?2000:12;$('#main').innerHTML=heading('Статистика','2026 год · чтение и прослушивание до 1 ноября.',`<select id="stats-year" aria-label="Год статистики"><option>2026 год</option><option>2025 год</option></select>`)+`<div class="metrics"><div class="metric"><span class="muted">Произведений завершено</span><strong>${total}</strong><small>${bookCount} книги · ${audioCount} аудиокниги</small></div><div class="metric"><span class="muted">Время с книгами</span><strong>${reading+audio} <small>ч</small></strong><small>${reading} ч чтения · ${audio} ч аудио</small></div><div class="metric"><span class="muted">Цель на год</span><strong>${total} <small>/ ${goal}</small></strong><small>Осталось ${Math.max(0,goal-total)} произведений</small></div></div><div class="chart-grid"><section class="panel"><h2>Завершено по месяцам</h2><p>Октябрь · ${activity[9]} завершено</p>${chart('bars')}</section><section class="panel"><h2>История за год</h2><p>Всего завершено · ${total}</p>${chart('line')}</section></div><div class="stats-bottom"><section class="panel"><h2>Время по форматам</h2><div class="ranking-row"><span>Чтение</span><span>${reading} ч · ${Math.round(reading/Math.max(1,reading+audio)*100)}%</span></div><div class="ranking-row"><span>Аудиокниги</span><span>${audio} ч · ${Math.round(audio/Math.max(1,reading+audio)*100)}%</span></div><p>Оба формата входят в общее время.</p></section><section class="panel"><h2>Ритм чтения</h2><div class="ranking-row"><span>Активных дней</span><span>186</span></div><div class="ranking-row"><span>Самая длинная серия</span><span>24 дня</span></div><p>Дни, когда читали или слушали хотя бы минуту.</p></section></div>`;$('#stats-year').onchange=()=>{if($('#stats-year').value==='2025 год'){$('#main').innerHTML=heading('Статистика','2025 год · история ещё не добавлена.')+'<section class="panel"><h2>0 завершённых произведений</h2><p>За этот год нет сохранённых сеансов.</p><button class="text-button" data-action="stats-current">Вернуться к 2026 году</button></section>'}};console.assert(total===bookCount+audioCount&&activity.reduce((a,b)=>a+b,0)===total,'Statistics totals must agree')}
function recommendations(){const b={...base[10],title:'Медленные дни'};$('#main').innerHTML=heading('Рекомендации','Следующая книга — под ваше настроение.')+`<div class="tab-row"><button aria-pressed="true" data-action="rec-tab">Для вас</button><button aria-pressed="false" data-action="rec-tab">Небольшие истории</button><button aria-pressed="false" data-action="rec-tab">В планах</button></div><div class="recommendation">${cover(b)}<div class="rec-main"><div class="rec-title"><small>После «Атласа тишины»</small><h2>${esc(b.title)}</h2><span class="muted">${esc(b.author)} · 196 страниц</span></div><p>Неспешная история о внимании к повседневности. Подойдёт, если хочется остаться в спокойном настроении, но сменить голос автора.</p><div class="header-actions"><button class="button primary" data-action="plan">${icon('plus')}В планы</button><button class="button secondary" data-action="another-rec">Другая книга ${icon('arrow')}</button></div></div></div><div class="content-section"><div class="section-title"><h2>Ещё немного тишины</h2><small>Короткие истории для вечера</small></div><div class="shelf">${base.slice(6,11).map(b=>`<button class="shelf-item" data-recommend="${b.id}">${cover(b)}<span class="book-name">${esc(b.title)}</span><span class="book-author">${esc(b.author)}</span></button>`).join('')}</div></div>`}
function quotes(){const rows=base.filter(b=>b.quotes>3).slice(0,6);$('#main').innerHTML=heading('Цитаты и заметки','Мысли, которые захотелось оставить рядом.')+`<div class="quote-list">${rows.map(b=>`<article class="quote-card"><blockquote>${esc(b.quote)}</blockquote><p>${esc(b.title)} · ${esc(b.author)}</p><button class="text-button" data-action="quote-book" data-id="${b.id}">К произведению ${icon('arrow')}</button></article>`).join('')}</div>`}

const lessons=[
  ['Как мы смотрим',21],['Точка и линия',24],['Пространство кадра',32],['Форма и равновесие',26],
  ['Искусство видеть',28],['Цвет как язык',34],['Работа со светом',25],['Ритм изображения',22],
  ['История фотографии',39],['Движение в кадре',31],['Визуальный дневник',23],['Свой взгляд',30]
];
const tracks=[['Тихий вечер','4:12'],['Свет за окном','3:48'],['Между строк','5:06'],['Медленный дождь','4:32'],['Пауза','3:24'],['Последняя страница','5:38']];
let selectedLesson=4;
const trackSeconds=tracks.reduce((sum,t)=>{const [m,s]=t[1].split(':').map(Number);return sum+m*60+s},0);
const trackTime=Math.floor(trackSeconds/60)+' мин '+trackSeconds%60+' с';
function courseArt(){
  const svg='<svg xmlns="http://www.w3.org/2000/svg" width="780" height="400" viewBox="0 0 780 400"><rect width="780" height="400" fill="#263e36"/><g fill="none" stroke="#a5b4a5" stroke-width="1.5"><path d="M420 340V70h215v270zM445 340V100h165v240M420 70l25 30m165 0 25-30M520 100v240M445 220h165"/><path d="M420 340h215l100 60H300z"/><circle cx="555" cy="158" r="24"/></g><text x="42" y="82" fill="#c4cdbb" font-size="16" font-family="sans-serif">История визуальной культуры</text><text x="40" y="161" fill="#eeeede" font-size="52" font-family="Georgia,serif">Искусство</text><text x="40" y="222" fill="#eeeede" font-size="52" font-family="Georgia,serif">видеть</text><text x="42" y="330" fill="#c4cdbb" font-size="16" font-family="sans-serif">Линия. Форма. Свет.</text></svg>';
  return '<img class="course-art" alt="Иллюстрация курса: окно, пространство и свет" src="data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg)+'" width="780" height="400">';
}
function media(){
  $('#main').innerHTML=heading('Медиа','Место для внимательного просмотра и спокойного фона.',primary('Добавить медиа','import'))+
    '<div class="media-layout"><section class="course-panel"><div class="course-visual">'+courseArt()+'</div><div class="course-copy"><div class="course-heading"><div><h2>История визуальной культуры</h2><p class="course-meta">Курс · '+lessons.length+' уроков</p></div><span class="completion">4 / '+lessons.length+'</span></div><div class="progress"><span style="width:'+(4/lessons.length*100)+'%"></span></div><div class="next-lesson"><div><h3>'+lessons[selectedLesson][0]+'</h3><p>Урок '+(selectedLesson+1)+' · '+lessons[selectedLesson][1]+' минут · видео</p></div><button class="button primary" data-action="media-open">'+icon('play')+'Смотреть</button></div><div class="course-source">'+icon('folder')+'<span>Папка курса · Визуальная культура</span></div></div></section>'+
    '<section class="music-panel"><div class="section-title"><h2>Музыка для чтения</h2><span class="muted">'+tracks.length+' композиций</span></div><div class="album-object"><div class="album-type">Между<br>строк</div><div class="album-credit">Личная подборка<br>'+trackTime+'</div></div><div class="track-list">'+tracks.map((t,i)=>'<button class="track-row" data-track="'+i+'"><span class="track-order">'+(i+1)+'</span><span>'+t[0]+'</span><span class="num">'+t[1]+'</span>'+icon('play')+'</button>').join('')+'</div><button class="text-button" data-action="music-open">Открыть подборку '+icon('arrow')+'</button></section></div>'+
    '<section class="lesson-section"><div class="section-title"><h2>Следующие уроки</h2><button class="text-button" data-action="all-lessons">Все '+lessons.length+' уроков '+icon('arrow')+'</button></div><div class="lesson-list">'+lessons.slice(4,7).map((l,i)=>'<button class="lesson-row '+(selectedLesson===i+4?'selected':'')+'" data-lesson="'+(i+4)+'"><span class="lesson-index">'+(i+5)+'</span><span><strong>'+l[0]+'</strong><small>История визуальной культуры</small></span><span class="num">'+l[1]+' мин</span>'+icon('play')+'</button>').join('')+'</div></section>';
}
function render(){renderNav();({library,books:()=>fileScreen(false),audio:()=>fileScreen(true),statistics,recommendations,quotes,media}[state.page]||library)();document.querySelectorAll('[data-icon]').forEach(e=>e.outerHTML=icon(e.dataset.icon))}
function openTrack(index){const t=tracks[index];if($('#dialog').open)$('#dialog').close();modal('<h2 id="dialog-title">'+t[0]+'</h2><p>Музыка для чтения · '+t[1]+'</p><div class="audio-preview"><span>'+icon('audio')+'</span><p>Аудиофайл не подключён.</p></div><p>Это концепт подборки. Воспроизведение доступно в рабочем приложении с вашими файлами.</p>')}
function modal(html){$('#dialog-content').innerHTML=html;$('#dialog').showModal()}
function edit(id){const b=archive.find(b=>b.id===Number(id))||base[0];modal(`<h2 id="dialog-title">Мои впечатления</h2><p>${esc(b.title)}</p><form id="edit-form"><label for="status-field">Статус в библиотеке</label><select id="status-field">${['finished','paused','abandoned'].map(s=>`<option value="${s}" ${b.status===s?'selected':''}>${labels[s]}</option>`).join('')}</select><label for="impression">Что осталось после книги</label><textarea id="impression">${esc(b.impression)}</textarea><div class="dialog-actions"><button type="button" class="button secondary" data-action="close-dialog">Отмена</button><button class="button primary">Сохранить</button></div></form>`);$('#edit-form').onsubmit=e=>{e.preventDefault();b.status=$('#status-field').value;b.impression=$('#impression').value;$('#dialog').close();render();toast('Впечатления сохранены в концепте')}}
function add(){modal(`<h2 id="dialog-title">Добавить в библиотеку</h2><p>История прочитанного и прослушанного начинается с вашей записи.</p><form id="add-form"><label for="title-field">Название</label><input id="title-field" required maxlength="120" placeholder="Название произведения"><label for="author-field">Автор</label><input id="author-field" required maxlength="80" placeholder="Имя автора"><label for="format-field">Формат</label><select id="format-field"><option value="book">Книга</option><option value="audio">Аудиокнига</option></select><label for="status-field">Статус</label><select id="status-field">${['finished','paused','abandoned'].map(s=>`<option value="${s}">${labels[s]}</option>`).join('')}</select><div class="dialog-actions"><button type="button" class="button secondary" data-action="close-dialog">Отмена</button><button class="button primary">Добавить запись</button></div></form>`);$('#add-form').onsubmit=e=>{e.preventDefault();const b={...base[0],id:Math.max(...archive.map(b=>b.id),0)+1,title:$('#title-field').value.trim(),author:$('#author-field').value.trim(),kind:$('#format-field').value,status:$('#status-field').value,quotes:0,rating:null,date:'1 ноября',impression:'Впечатления ещё не добавлены.',quote:'Сохранённых цитат пока нет.'};if(!b.title||!b.author)return;archive.unshift(b);state.selected=b.id;state.scenario='normal';$('#scenario').value='normal';state.filter='all';state.kind='all';state.query='';$('#dialog').close();render();toast('Запись добавлена в демонстрационный архив')}}
function setScenario(value){state.scenario=value;$('#scenario').value=value;archive=value==='large'?Array.from({length:2400},(_,i)=>({...base[i%base.length],id:i+1,title:i<12?base[i%12].title:`${base[i%12].title} · том ${Math.floor(i/12)+1}`})):base.map(b=>({...b}));state.selected=1;state.filter='all';state.kind='all';state.query='';state.mobileDetail=false;if(state.page!=='library'){state.page='library';location.hash='library'}render()}
document.addEventListener('click',e=>{
  const dt=e.target.closest('[data-detail-tab]');if(dt){state.detailTab=dt.dataset.detailTab;renderDetail();$('#'+(state.detailTab==='impression'?'impression-tab':'quotes-tab')).focus();return}
  const lesson=e.target.closest('[data-lesson]');if(lesson){selectedLesson=Number(lesson.dataset.lesson);media();return}
  const ml=e.target.closest('[data-modal-lesson]');if(ml){selectedLesson=Number(ml.dataset.modalLesson);$('#dialog').close();media();return}
  const track=e.target.closest('[data-track]');if(track){openTrack(Number(track.dataset.track));return}
  const filter=e.target.closest('[data-filter]');if(filter){state.filter=filter.dataset.filter;state.mobileDetail=false;library();return}
  const book=e.target.closest('[data-book]');if(book){state.selected=Number(book.dataset.book);state.mobileDetail=true;$('.archive-layout').classList.add('mobile-detail');paintRows();renderDetail();if(matchMedia('(max-width:700px)').matches)$('#detail').scrollIntoView({block:'start'});return}
  const ff=e.target.closest('[data-file-filter]');if(ff){state.fileFilter=ff.dataset.fileFilter;fileScreen(state.page==='audio');return}
  const f=e.target.closest('[data-file]');if(f){const b=[...files,...audioFiles].find(b=>b.id===Number(f.dataset.file));modal(`<h2 id="dialog-title">${esc(b.title)}</h2><p>${esc(b.author)} · ${labels[b.status]}</p><button class="button primary" data-action="${b.kind==='audio'?'listen':'read'}">${icon('play')}${b.kind==='audio'?'Открыть плеер':'Открыть читалку'}</button><div class="dialog-actions"><button class="button secondary" data-action="archive-file" data-id="${b.id}">Добавить в библиотеку</button></div>`);return}
  const rec=e.target.closest('[data-recommend]');if(rec){modal(`<h2 id="dialog-title">${esc(base.find(b=>b.id===Number(rec.dataset.recommend)).title)}</h2><p>История для вашего следующего вечера.</p><button class="button primary" data-action="plan">Добавить в планы</button>`);return}
  const el=e.target.closest('[data-action]');if(!el)return;const action=el.dataset.action;
  if(action==='close-dialog')$('#dialog').close();
  else if(action==='menu'){const open=$('#navigation').classList.toggle('open');el.setAttribute('aria-expanded',String(open));el.setAttribute('aria-label',open?'Закрыть навигацию':'Открыть навигацию')}
  else if(action==='add')add();
  else if(action==='edit')edit(el.dataset.id);
  else if(action==='back-list'){state.mobileDetail=false;$('.archive-layout').classList.remove('mobile-detail')}
  else if(action==='reset'){state.filter='all';state.kind='all';state.query='';library()}
  else if(action==='retry')setScenario('normal');
  else if(action==='stats-current')statistics();
  else if(action==='quote-book'){state.selected=Number(el.dataset.id);state.page='library';location.hash='library';render()}
  else if(action==='import')modal('<h2 id="dialog-title">Добавить файлы</h2><p>Подключённая папка появится в разделе файлов. Сохранить произведение в личную библиотеку можно отдельным действием.</p><label for="demo-file">Попробовать выбор файла</label><input id="demo-file" type="file" accept=".epub,.fb2,.pdf,.txt,.mp3,.m4b" multiple><div class="dialog-actions"><button class="button primary" data-action="import-done">Готово</button></div>');
  else if(action==='import-done'){const amount=$('#demo-file')?.files?.length||0;$('#dialog').close();toast(amount?`Выбрано файлов: ${amount}. Импорт доступен в рабочем приложении.`:'Файлы не выбраны')}
  else if(action==='archive-file'){const b=[...files,...audioFiles].find(b=>b.id===Number(el.dataset.id));modal(`<h2 id="dialog-title">Сохранить в библиотеку</h2><p>${esc(b.title)}</p><label for="archive-status">Как закончилась эта история?</label><select id="archive-status"><option value="finished">Завершено</option><option value="paused">Отложено</option><option value="abandoned">Брошено</option></select><div class="dialog-actions"><button class="button primary" data-action="archive-confirm" data-id="${b.id}">Сохранить запись</button></div>`)}
  else if(action==='archive-confirm'){const b=[...files,...audioFiles].find(b=>b.id===Number(el.dataset.id));archive.unshift({...b,id:Math.max(...archive.map(b=>b.id))+1,status:$('#archive-status').value});$('#dialog').close();toast('Запись добавлена в демонстрационную библиотеку')}
  else if(action==='read')modal('<h2 id="dialog-title">Архитектура привычек</h2><div class="reader-copy"><h3>Маленькие действия</h3><p>Новый день начинается задолго до того, как мы решаем, каким он будет. Его складывают простые вещи: открытая книга, свободный стол, несколько минут внимания.</p><p>Не обязательно менять всё сразу. Иногда достаточно оставить место для одной хорошей привычки.</p></div><p>Демонстрационный фрагмент · позиция 31%</p>');
  else if(action==='listen')modal('<h2 id="dialog-title">Атлас тишины</h2><p>Михаил Лесной · Глава 7 из 16</p><div class="progress-label"><span>2 ч 28 мин</span><span>5 ч 52 мин</span></div><div class="progress"><span style="width:42%"></span></div><div class="dialog-actions"><button class="button primary" data-action="demo-play">Прослушать</button></div><p>Концепт плеера · аудиофайл не подключён</p>');
  else if(action==='demo-play')toast('Для воспроизведения нужен аудиофайл в рабочем приложении');
  else if(action==='plan'){const added={...base[10],id:400+files.length,status:'planned',progress:0};files.push(added);$('#dialog').close();el.disabled=true;el.textContent='Добавлено в планы';toast('Книга сохранена в планах раздела «Книги»')}
  else if(action==='another-rec'){const title=$('.rec-title h2');title.textContent=title.textContent==='Медленные дни'?'Письма из сада':'Медленные дни';$('.rec-title .muted').textContent=title.textContent==='Медленные дни'?'Нина Тихая · 196 страниц':'Вера Липова · 180 страниц';$('.recommendation>.cover').outerHTML=cover(title.textContent==='Медленные дни'?base[10]:base[6])}
  else if(action==='rec-tab'){document.querySelectorAll('.tab-row button').forEach(b=>b.setAttribute('aria-pressed',String(b===el)));if(el.textContent==='В планах'){state.fileFilter='planned';location.hash='books'}else{const sub=$('.rec-title small');sub.textContent=el.textContent==='Для вас'?'После «Атласа тишины»':'История на несколько вечеров'}}
  else if(action==='media-open')modal('<h2 id="dialog-title">'+lessons[selectedLesson][0]+'</h2><p>Урок '+(selectedLesson+1)+' из '+lessons.length+' · '+lessons[selectedLesson][1]+' минут</p>'+courseArt()+'<p>Для просмотра подключите видеофайл в рабочем приложении.</p>');
  else if(action==='all-lessons')modal('<h2 id="dialog-title">Содержание курса</h2><p>'+lessons.length+' уроков · 4 просмотрено</p><div class="full-lessons">'+lessons.map((l,i)=>'<button class="lesson-row" data-modal-lesson="'+i+'"><span class="lesson-index">'+(i<4?icon('check'):i+1)+'</span><span>'+l[0]+'</span><span class="num">'+l[1]+' мин</span></button>').join('')+'</div>');
  else if(action==='music-open')modal('<h2 id="dialog-title">Музыка для чтения</h2><p>'+tracks.length+' композиций · '+trackTime+'</p><div class="track-list">'+tracks.map((t,i)=>'<button class="track-row" data-track="'+i+'"><span class="track-order">'+(i+1)+'</span><span>'+t[0]+'</span><span class="num">'+t[1]+'</span>'+icon('play')+'</button>').join('')+'</div>');
  else if(action==='settings')modal('<h2 id="dialog-title">Оформление</h2><p>Тихий архив · тёмное направление</p><label for="text-size">Размер текста</label><select id="text-size"><option value="14">Обычный</option><option value="16">Крупный</option></select><label for="density">Плотность списков</label><select id="density"><option>Комфортная</option><option disabled>Компактная — в следующей итерации</option></select><div class="dialog-actions"><button class="button primary" data-action="settings-save">Применить</button></div>');
  else if(action==='settings-save'){document.body.classList.toggle('large-text',$('#text-size').value==='16');$('#dialog').close();toast('Оформление применено в концепте')}
});
$('#scenario').onchange=e=>setScenario(e.target.value);
window.addEventListener('hashchange',()=>{const page=location.hash.slice(1);state.page=navItems.some(i=>i[0]===page)?page:'library';state.mobileDetail=false;$('#navigation').classList.remove('open');render();window.scrollTo(0,0)});
if(navItems.some(i=>i[0]===location.hash.slice(1)))state.page=location.hash.slice(1);
render();
console.assert(base.every(b=>['finished','paused','abandoned'].includes(b.status)),'Archive statuses must be finished, paused or abandoned');

document.addEventListener('keydown',e=>{
  const tab=e.target.closest('[data-detail-tab]');
  if(!tab||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;
  e.preventDefault();
  state.detailTab=e.key==='Home'?'impression':e.key==='End'?'quotes':state.detailTab==='quotes'?'impression':'quotes';
  renderDetail();$('#'+(state.detailTab==='impression'?'impression-tab':'quotes-tab')).focus();
});
