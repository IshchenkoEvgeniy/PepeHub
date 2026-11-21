// «Библиотека»: personal archive of finished / paused / abandoned works,
// plus the work card, notes, series editor and trash.
'use strict';
const { C, FONT, F, H, V, T, I, R, Book, Spacer } = require('../lib');
const { DesktopScreen, PhoneScreen, SubScreen, Search, Chip, Badge, Button, Cover, CoverIcon, ProgressBar, Card, SectionLabel, IconButton, COVERS } = require('../components');

const ROWS = [
  [0, 'menu_book_outlined', 'Завершено', 1, '320 / 320 стр.', '5'],
  [1, 'headphones_outlined', 'Завершено', 1, '6:00:00', '4'],
  [3, 'headphones_outlined', 'Отложено', 0.42, '2:31:10 / 6:00:00', '–'],
  [4, 'menu_book_outlined', 'Брошено', 0.18, '58 / 320 стр.', '2'],
  [5, 'menu_book_outlined', 'Не прочитано', 0, 'Том 2 серии', '–'],
];

const col = (w, children, props = {}) => H('Cell', { width: w, sizingH: 'fixed', crossAlign: 'center', ...props }, children);

function TableHeader() {
  return H('TableHeader', { sizingH: 'fill', padding: [8, 16, 8, 16], crossAlign: 'center' }, [
    T('Название', { size: 11, w: 500, color: C.muted, sizingH: 'fill' }),
    col(46, [T('Тип', { size: 11, w: 500, color: C.muted })]),
    col(100, [T('Статус', { size: 11, w: 500, color: C.muted })]),
    col(120, [T('Прогресс', { size: 11, w: 500, color: C.muted })]),
    col(64, [T('Оценка', { size: 11, w: 500, color: C.muted })]),
    F('More', { width: 40, height: 1 }),
  ]);
}

function Row([cover, icon, status, progress, label, rating], selected) {
  const [, title, author] = COVERS[cover];
  return H(`Row/${title}`, { sizingH: 'fill', height: 82, sizingV: 'fixed', padding: [0, 16, 0, 16], gap: 12, crossAlign: 'center', ...(selected ? { fill: C.selected, strokeLeftWeight: 3, stroke: C.accent } : { strokeBottomWeight: 1, stroke: C.line }) }, [
    Cover(cover, 36, 52, { detail: false, radius: 3 }),
    V('Title', { sizingH: 'fill', gap: 2 }, [Book(title, 16), T(author, { size: 11, color: C.muted })]),
    col(46, [I(icon, 18, C.muted)]),
    col(100, [Badge(status, C.muted)]),
    col(120, [V('Progress', { sizingH: 'fill', gap: 4 }, [T(`${Math.round(progress * 100)}%`, { size: 11 }), ProgressBar(progress, { width: 108, fill: '#bdbdbd', height: 3 }), T(label, { size: 9, color: C.muted })])]),
    col(64, [T(rating === '–' ? '–' : `${rating} из 5`, { size: 12, color: rating === '–' ? C.accent : C.text })]),
    F('More', { width: 40, height: 40, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I('more_horiz', 20)]),
  ]);
}

function Detail() {
  const kv = (k, v) => V(k, { sizingH: 'fill', gap: 6 }, [T(k, { size: 10, w: 500, color: C.muted }), T(v, { size: 12, color: C.muted })]);
  return Card('Detail', { width: 280, sizingH: 'fixed', padding: [24, 18, 18, 18], gap: 14, cornerRadius: 20 }, [
    H('Head', { sizingH: 'fill', crossAlign: 'center' }, [T('Карточка книги', { size: 13, w: 700, sizingH: 'fill' }), I('edit', 18, C.muted)]),
    H('Book', { sizingH: 'fill', gap: 14 }, [
      Cover(0, 62, 92, { detail: false, radius: 4 }),
      V('Text', { sizingH: 'fill', gap: 4 }, [T('Книга', { size: 9, color: C.muted }), Book('Архитектура привычек', 20, C.text, { sizingH: 'fill', textAutoResize: 'height' }), T('Елена Соколова', { size: 11, color: C.muted })]),
    ]),
    H('Status', { sizingH: 'fill', height: 26, sizingV: 'fixed', padding: [0, 9, 0, 9], cornerRadius: 6, stroke: C.strong, strokeWeight: 1, crossAlign: 'center' }, [T('Завершено', { size: 11, w: 700, color: C.muted })]),
    V('Progress', { sizingH: 'fill', gap: 6 }, [T('100%', { size: 11 }), ProgressBar(1, { width: 244, fill: '#bdbdbd', height: 3 }), T('320 / 320 стр.', { size: 9, color: C.muted })]),
    R('Divider', { width: 244, height: 1, fill: C.line }),
    H('Dates', { sizingH: 'fill' }, [kv('Дата начала', '12 сентября'), kv('Дата завершения', '31 октября')]),
    H('More', { sizingH: 'fill' }, [kv('Формат', 'EPUB'), kv('Ваша оценка', '5 из 5')]),
    Button('Открыть карточку произведения', { icon: 'edit', fillWidth: true, height: 58 }),
    Button('Журнал этой книги', { icon: 'history', kind: 'outline', fillWidth: true }),
    H('Footer', { sizingH: 'fill', mainAlign: 'center', gap: 6, crossAlign: 'center' }, [I('local_library_outlined', 12, C.accent), T('В библиотеке', { size: 10, color: C.muted })]),
  ]);
}

function Filters({ phone = false } = {}) {
  return [
    H('Kinds', { gap: 8 }, [Chip('Все', 'accent', { height: 34, size: 13 }), Chip('Книги', 'outline', { height: 34, size: 13 }), Chip('Аудиокниги', 'outline', { height: 34, size: 13 })]),
    H('Statuses', { gap: 8, wrap: phone, sizingH: phone ? 'fill' : 'hug', crossGap: 8 }, [Chip('Все статусы', 'accent', { height: 34, size: 13 }), Chip('Завершено · 2', 'outline', { height: 34, size: 13 }), Chip('Отложено · 1', 'outline', { height: 34, size: 13 }), Chip('Брошено · 1', 'outline', { height: 34, size: 13 }), Chip('Не прочитано · 1', 'outline', { height: 34, size: 13 })]),
  ];
}

const libraryDesktop = DesktopScreen('Библиотека — десктоп', 'library', 'Библиотека', ['more_vert', 'backup_outlined'], [
  H('Columns', { sizingH: 'fill', sizingV: 'fill', gap: 24 }, [
    V('Main', { sizingH: 'fill', gap: 16, padding: [12, 0, 0, 0] }, [
      H('Summary', { sizingH: 'fill', crossAlign: 'center', gap: 12 }, [T('Показано 5 из 5', { size: 12, color: C.muted, sizingH: 'fill' }), I('checklist', 22, C.muted), H('Add', { gap: 6, crossAlign: 'center', padding: [0, 16, 0, 8] }, [I('add', 20, C.accent), T('Добавить', { size: 15, w: 500, color: C.accent })])]),
      H('Year', { sizingH: 'fill', crossAlign: 'center' }, [T('2026 · книг: 3 · аудиокниг: 2', { size: 13, w: 500, sizingH: 'fill' }), I('expand_more', 22, C.muted)]),
      Search('Название, автор или серия…', { trailing: 'tune' }),
      ...Filters(),
      H('Sort', { sizingH: 'fill', crossAlign: 'center', gap: 8 }, [T('По дате завершения', { size: 13, w: 500, sizingH: 'fill' }), I('arrow_drop_down', 22, C.muted), I('arrow_downward', 20, C.muted), F('List', { width: 40, height: 40, cornerRadius: 20, fill: C.accent, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I('library_books_outlined', 20, C.onAccent)]), IconButton('grid_view_rounded', { color: C.muted })]),
      V('Table', { sizingH: 'fill' }, [TableHeader(), ...ROWS.map((r, i) => Row(r, i === 0))]),
    ]),
    Detail(),
  ]),
]);

const libraryPhone = PhoneScreen('Библиотека — телефон', 'library', 'Библиотека', ['more_vert', 'backup_outlined'], [
  V('Main', { sizingH: 'fill', gap: 14, padding: [8, 0, 0, 0] }, [
    H('Summary', { sizingH: 'fill', crossAlign: 'center', gap: 12 }, [T('Показано 5 из 5', { size: 12, color: C.muted, sizingH: 'fill' }), I('checklist', 22, C.muted), H('Add', { gap: 6, crossAlign: 'center' }, [I('add', 20, C.accent), T('Добавить', { size: 14, w: 500, color: C.accent })])]),
    Search('Название, автор или серия…', { trailing: 'tune' }),
    ...Filters({ phone: true }),
    V('Cards', { sizingH: 'fill', gap: 10 }, ROWS.slice(0, 4).map(([cover, icon, status, progress, label]) => H(`Card/${COVERS[cover][1]}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 14, padding: 12, gap: 12, crossAlign: 'center' }, [
      Cover(cover, 44, 64, { detail: false, radius: 3 }),
      V('Text', { sizingH: 'fill', gap: 4 }, [Book(COVERS[cover][1], 15), T(COVERS[cover][2], { size: 11, color: C.muted }), H('Meta', { gap: 8, crossAlign: 'center' }, [Badge(status), I(icon, 14, C.muted), T(label, { size: 10, color: C.muted })])]),
      I('more_horiz', 20),
    ]))),
  ]),
]);

// Карточка произведения (LibraryWorkPage).
const work = SubScreen('Карточка произведения', 'Карточка произведения', ['edit', 'more_vert'], [
  V('Column', { sizingH: 'fill', padding: [12, 180, 0, 180], gap: 14, crossAlign: 'center' }, [
    F('Cover', { width: 150, height: 226, fill: '#4a4370', cornerRadius: 4, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I('auto_stories_outlined', 64, '#b0b0c0')]),
    V('Head', { sizingH: 'fill', gap: 10 }, [T('Северный ветер', { size: 26, w: 500 }), Chip('Анна Волкова', 'outline', { height: 36, size: 13 })]),
    Chip('Серия: Морские истории', 'outline', { height: 36, size: 13 }),
    H('Status', { sizingH: 'fill', height: 56, sizingV: 'fixed', fill: C.surface, cornerRadius: 14, stroke: C.line, strokeWeight: 1, padding: [0, 20, 0, 24], crossAlign: 'center' }, [T('Завершено', { size: 14, sizingH: 'fill' }), I('arrow_drop_down', 24, C.muted)]),
    H('Chips', { sizingH: 'fill', gap: 12 }, [Chip('Оценка: 5 из 5', 'outline', { height: 36, size: 13 }), Chip('Книга', 'outline', { height: 36, size: 13 }), Chip('Избранное', 'outline', { height: 36, size: 13, icon: 'favorite_border' })]),
    V('Progress', { sizingH: 'fill', gap: 8 }, [T('Общий прогресс: 320 / 320 стр.', { size: 14, w: 500 }), ProgressBar(1, { width: 870, height: 4 }), T('100 %', { size: 13 })]),
    R('Divider', { width: 870, height: 1, fill: C.line }),
    V('Dates', { sizingH: 'fill', gap: 12 }, ['Добавлена: 3 сентября', 'Начало: 12 сентября', 'Завершение: 31 октября', 'Перечитываний: 0'].map((t) => T(t, { size: 14, w: 500 }))),
    H('Again', { gap: 8, crossAlign: 'center' }, [I('repeat', 18, C.accent), T('Завершено ещё раз', { size: 14, w: 500, color: C.accent })]),
    R('Divider', { width: 870, height: 1, fill: C.line }),
    H('Impressions', { sizingH: 'fill', crossAlign: 'center' }, [T('Впечатления', { size: 16, w: 500, sizingH: 'fill' }), I('edit', 20, C.muted)]),
    T('Спокойная и светлая книга о том, как замечать маленькие вещи. Хочется возвращаться к главам о набережной.', { size: 14, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }),
    R('Divider', { width: 870, height: 1, fill: C.line }),
    V('Quotes', { sizingH: 'fill', gap: 4 }, [T('Цитаты и заметки · 3', { size: 22, w: 500 }), T('Сохранённые цитаты появятся здесь.', { size: 13, color: C.muted })]),
  ]),
]);

module.exports = [libraryDesktop, libraryPhone, work];
