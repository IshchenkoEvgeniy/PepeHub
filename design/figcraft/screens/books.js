// «Книги»: shelf of book files (grid on desktop, list on phone).
'use strict';
const { C, FONT, F, H, V, T, I, R, Book, Spacer } = require('../lib');
const { DesktopScreen, PhoneScreen, Search, Chip, Badge, Cover, ProgressBar, Tabs, IconButton, COVERS } = require('../components');

const STATUS = [
  ['Завершено', C.muted, 0.98], ['Читаю', C.accent, 0.31], ['В планах', C.accentSoft, 0],
  ['В планах', C.accentSoft, 0], ['В планах', C.accentSoft, 0], ['Читаю', C.accent, 0.24],
];

const tabs = (audio) => audio
  ? [['Все', 0], ['Слушаю', 0], ['В планах', 0], ['Отложены', 0], ['Брошены', 0], ['Прослушано', 0]]
  : [['Все', 6], ['Читаю', 2], ['В планах', 3], ['Отложены', 0], ['Брошены', 0], ['Прочитано', 1]];

function Toolbar(view = 'grid') {
  const tool = (icon, sel) => F(`Tool/${icon}`, { width: 40, height: 40, cornerRadius: 20, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center', ...(sel && { fill: C.accent }) }, [I(icon, 24, sel ? C.onAccent : C.text)]);
  return H('Toolbar', { gap: 4, crossAlign: 'center' }, [
    Chip('Фильтры', 'outline', { icon: 'tune', height: 44, size: 14 }),
    F('Gap', { width: 8, height: 1 }),
    tool('sort'),
    tool('table_view_outlined', view === 'list'),
    tool('grid_view', view === 'grid'),
    tool('collections_bookmark'),
    tool('checklist'),
    tool('sync'),
  ]);
}

function GridCard(i) {
  const [, title, author] = COVERS[i], [status, color, progress] = STATUS[i];
  return V(`BookCard/${title}`, { width: 201, sizingH: 'fixed', height: 461, sizingV: 'fixed', fill: C.surface, cornerRadius: 16, clip: true }, [
    Cover(i, 201, 297, { radius: 0 }),
    ProgressBar(progress, { width: 201, track: '#00000000', fill: i === 0 ? '#bdbdbd' : C.accent }),
    V('Info', { sizingH: 'fill', sizingV: 'fill', padding: [12, 12, 10, 12], gap: 2 }, [
      Book(title, 15, C.text, { sizingH: 'fill', textAutoResize: 'height' }),
      T(author, { size: 12, color: C.muted }),
      Spacer('v'),
      H('Footer', { sizingH: 'fill', crossAlign: 'center', gap: 6 }, [
        Badge(status, color), T(`${Math.round(progress * 100)}%`, { size: 11, color: C.muted }), Spacer('h'), I('more_vert', 20, C.muted),
      ]),
    ]),
  ]);
}

function ListCard(i) {
  const [, title, author] = COVERS[i], [status, color, progress] = STATUS[i];
  return H(`BookRow/${title}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 16, padding: [16, 12, 16, 14], gap: 14, crossAlign: 'center' }, [
    Cover(i, 54, 80, { detail: false, radius: 3 }),
    V('Info', { sizingH: 'fill', gap: 4 }, [
      Book(title, 16, C.text),
      T(author, { size: 12, color: C.muted }),
      i === 1 && T('Морские истории', { size: 11, color: C.accent }),
      H('Meta', { gap: 10, crossAlign: 'center', padding: [4, 0, 4, 0] }, [Badge(status, color), T(`TXT · ${(progress * 100).toFixed(1)}%`, { size: 11, color: C.muted })]),
      ProgressBar(progress, { width: 240, fill: i === 0 ? '#bdbdbd' : C.accent, height: 3 }),
    ]),
    I('more_vert', 22, C.muted),
  ]);
}

function Empty(icon, title, text) {
  return V('EmptyState', { sizingH: 'fill', crossAlign: 'center', gap: 8, padding: [64, 0, 0, 0] }, [
    I(icon, 48, '#7f9a8a'), T(title, { size: 18, w: 700 }), T(text, { size: 13 }),
  ]);
}

const booksDesktop = DesktopScreen('Книги — десктоп', 'books', 'Книги', ['edit_note', 'folder_outlined', 'bar_chart', 'add'], [
  Tabs(tabs(false), 0),
  F('Gap', { width: 1, height: 24 }),
  Search('Название, автор или серия'),
  F('Gap', { width: 1, height: 12 }),
  Toolbar('grid'),
  F('Gap', { width: 1, height: 26 }),
  H('Grid', { sizingH: 'fill', gap: 18 }, COVERS.map((_, i) => GridCard(i))),
]);

const booksPhone = PhoneScreen('Книги — телефон', 'books', 'Книги', ['edit_note', 'folder_outlined', 'bar_chart', 'add'], [
  Tabs(tabs(false).slice(0, 5), 0, { size: 16 }),
  F('Gap', { width: 1, height: 22 }),
  Search('Название, автор или серия'),
  F('Gap', { width: 1, height: 10 }),
  Toolbar('list'),
  F('Gap', { width: 1, height: 18 }),
  V('List', { sizingH: 'fill', gap: 12 }, [0, 1, 2, 3, 4].map(ListCard)),
]);

const audioDesktop = DesktopScreen('Аудиокниги — пусто', 'audio', 'Аудиокниги', ['folder_outlined', 'bar_chart', 'add'], [
  Tabs(tabs(true), 0),
  F('Gap', { width: 1, height: 22 }),
  H('NewCard', { gap: 8, padding: [8, 0, 16, 16], crossAlign: 'center' }, [I('add', 20, C.accent), T('Новая карточка без файла', { size: 14, w: 500, color: C.accent })]),
  Search('Название, автор или серия'),
  F('Gap', { width: 1, height: 12 }),
  Toolbar('grid'),
  Empty('collections_bookmark', 'Начните с первой книги', 'Подключите папку или добавьте книгу.'),
]);

module.exports = [booksDesktop, booksPhone];
module.exports.audioDesktop = audioDesktop;
module.exports.Toolbar = Toolbar;
module.exports.Empty = Empty;
