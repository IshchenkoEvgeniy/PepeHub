// Reader, quotes and notes.
'use strict';
const { C, FONT, F, H, V, T, I, R, Book, Display, Spacer } = require('../lib');
const { DesktopScreen, Search, Chip, IconButton, SectionLabel } = require('../components');

const P = [
  ['В тот вечер северный ветер принёс в город запах моря. Анна остановилась на пустой набережной и впервые за долгое время никуда не спешила.', null],
  ['Она достала из кармана маленький блокнот. На первой странице было всего три слова: «Замечать. Запоминать. Возвращаться». За этими словами начиналась история, которую она собиралась написать.', '#ffdd80'],
  ['За рекой зажглись окна старой библиотеки. Между полками там всегда находилось место для неожиданной встречи — с человеком, с мыслью, с книгой, которую раньше не замечаешь.', '#a6cdf2'],
  ['Чтение не требовало от неё закончить всё сегодня. Достаточно было одной главы, одной отмеченной строки, одного вопроса, который хотелось унести с собой.', '#a6dfae'],
  ['Город медленно стихал. Вдали прозвучал корабельный гудок, и Анна улыбнулась: иногда путь начинается с разрешения остановиться.', null],
];

function Page(width, size = 22, padding = [24, 40, 16, 34]) {
  return V('Page', { sizingH: 'fill', sizingV: 'fill', fill: C.paper, padding, gap: 28 }, [
    ...P.map(([text, hl], i) => {
      const t = T(text, { font: FONT.reading, size, color: C.ink, lineHeight: '145%', sizingH: 'fill', textAutoResize: 'height', name: `Paragraph ${i + 1}` });
      return hl ? V(`Highlight ${i + 1}`, { sizingH: 'fill', fill: hl }, [t]) : t;
    }),
    Spacer('v'),
    H('Footer', { sizingH: 'fill' }, [T('16:25', { size: 11, color: '#9a9a9a' }), Spacer('h'), T('Северный ветер', { size: 11, color: '#9a9a9a' }), Spacer('h'), T('0.00%   1/1', { size: 11, color: '#9a9a9a' })]),
  ]);
}

const readerDesktop = H('Читалка — десктоп', { width: 1200, height: 900, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
  V('Contents', { width: 280, sizingH: 'fixed', sizingV: 'fill', padding: [20, 10, 10, 10], gap: 14 }, [
    H('Head', { sizingH: 'fill', padding: [0, 8, 0, 10], crossAlign: 'center' }, [Display('ОГЛАВЛЕНИЕ', 18), Spacer('h'), T('Глав: 3', { size: 11, w: 500, color: C.muted })]),
    Search('Найти главу'),
    V('Chapters', { sizingH: 'fill', gap: 2 }, ['Глава 1. Набережная', 'Глава 2. Старый маяк', 'Глава 3. Письмо'].map((t, i) => H(`Chapter ${i + 1}`, { sizingH: 'fill', height: 34, sizingV: 'fixed', padding: [0, 10, 0, 10], gap: 16, cornerRadius: 10, crossAlign: 'center', ...(i === 0 && { fill: C.surface }) }, [T(String(i + 1), { size: 11, color: C.accent }), T(t, { size: 12, w: i === 0 ? 700 : 500, sizingH: 'fill', color: i === 0 ? C.text : C.muted }), T(i === 0 ? '0%' : '', { size: 11, color: C.accent })]))),
  ]),
  Page(920),
]);

// Reader controls overlay on the phone.
const readerPhone = V('Читалка — телефон', { width: 430, height: 932, sizingH: 'fixed', sizingV: 'fixed', fill: C.paper, clip: true }, [
  H('TopBar', { sizingH: 'fill', height: 56, sizingV: 'fixed', fill: C.surface, padding: [0, 4, 0, 4], crossAlign: 'center' }, [IconButton('arrow_back'), V('Title', { sizingH: 'fill' }, [Book('Северный ветер', 16), T('Глава 1. Набережная', { size: 11, color: C.muted })]), IconButton('search'), IconButton('bookmark_border'), IconButton('more_vert')]),
  Page(430, 18, [20, 22, 12, 22]),
  V('BottomBar', { sizingH: 'fill', fill: C.surface, padding: [10, 16, 14, 16], gap: 8 }, [
    H('Progress', { sizingH: 'fill', gap: 10, crossAlign: 'center' }, [T('12%', { size: 11, color: C.muted }), F('Track', { sizingH: 'fill', width: 10, height: 4, fill: C.raised, cornerRadius: 2 }, [R('Value', { width: 40, height: 4, fill: C.accent, x: 0, y: 0 })]), T('стр. 14 / 120', { size: 11, color: C.muted })]),
    H('Tools', { sizingH: 'fill', mainAlign: 'spaceBetween' }, ['format_list_bulleted', 'notes', 'text_format', 'contrast', 'headphones_outlined'].map((i) => IconButton(i, { color: C.text }))),
  ]),
]);

// Quotes and notes (ReadingNotesPage).
function NoteCard(text, comment, tag, color) {
  return H(`Note/${tag}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 18, clip: true, strokeLeftWeight: 5, stroke: color, strokeAlign: 'inside' }, [
    V('Body', { sizingH: 'fill', padding: [18, 14, 16, 18], gap: 10 }, [
      H('Quote', { sizingH: 'fill', gap: 8 }, [T(text, { font: FONT.serif, w: 700, size: 20, lineHeight: '140%', sizingH: 'fill', textAutoResize: 'height' }), I('more_vert', 22)]),
      T(comment, { size: 13, w: 500, sizingH: 'fill', textAutoResize: 'height' }),
      H('Meta', { gap: 8 }, [T('Северный ветер · Глава 1. Набережная', { size: 12, color: C.muted }), T(`#${tag}`, { size: 12, w: 700, color: C.accent })]),
      T('Персонажи: Анна', { size: 12, color: C.muted }),
    ]),
  ]);
}

const notesDesktop = DesktopScreen('Заметки', 'books', 'Заметки', ['file_download_outlined'], [
  T('Показано 3 из 3', { size: 13, color: C.muted }),
  F('Gap', { width: 1, height: 20 }),
  H('Columns', { sizingH: 'fill', gap: 24 }, [
    V('Filters', { width: 250, sizingH: 'fixed', gap: 10 }, [
      Search('Цитаты, комментарии, т…'),
      Display('ЦВЕТ', 18),
      ...[['Все цвета', 3, null], ['Жёлтый', 1, '#ffdd80'], ['Зелёный', 1, '#a6dfae'], ['Синий', 1, '#a6cdf2'], ['Розовый', 0, '#f2a6c8']].map(([t, n, c], i) => H(`Color/${t}`, { sizingH: 'fill', height: 34, sizingV: 'fixed', padding: [0, 10, 0, 10], gap: 10, cornerRadius: 8, crossAlign: 'center', ...(i === 0 && { fill: C.selected }) }, [c && { kind: 'ellipse', name: 'Dot', props: { width: 12, height: 12, fill: c } }, T(t, { size: 13, w: i === 0 ? 700 : 500, sizingH: 'fill' }), T(String(n), { size: 12, color: C.muted })])),
      Display('ТЕГИ', 18),
      H('Tags', { sizingH: 'fill', wrap: true, gap: 8, crossGap: 8 }, ['#Идеи', '#Привычки', '#Тишина'].map((t) => Chip(t, 'outline', { height: 36, size: 13 }))),
      Display('ПЕРСОНАЖИ', 18),
      Chip('Анна', 'outline', { height: 36, size: 13 }),
    ]),
    V('Notes', { sizingH: 'fill', gap: 12 }, [
      NoteCard('Чтение не требовало от неё закончить всё сегодня. Достаточно было одной главы, одной отмеченной строки…', 'Одна глава в день — хороший ритм.', 'Привычки', '#a6dfae'),
      NoteCard('Она достала из кармана маленький блокнот. На первой странице было всего три слова…', 'Хочу возвращаться к этой мысли, когда день становится слишком шумным.', 'Идеи', '#ffdd80'),
      NoteCard('За рекой зажглись окна старой библиотеки. Между полками там всегда находилось место для неожиданной встречи…', 'Библиотека как место встречи, а не просто хранения книг.', 'Тишина', '#a6cdf2'),
    ]),
    V('Hint', { width: 340, sizingH: 'fixed', cornerRadius: 18, stroke: C.line, strokeWeight: 1, padding: 20 }, [T('Выберите заметку, чтобы увидеть её целиком. Двойное нажатие открывает место в книге.', { size: 12, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' })]),
  ]),
], { bodyPadding: [0, 28, 20, 28] });

module.exports = [readerDesktop, readerPhone, notesDesktop];
