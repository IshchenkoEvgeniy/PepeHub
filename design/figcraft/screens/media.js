// «Медиа»: video, courses and music.
'use strict';
const { C, F, H, V, T, I, Spacer } = require('../lib');
const { DesktopScreen, PhoneScreen, Search, Chip, ProgressBar, IconButton } = require('../components');

function Filters(count) {
  return [
    H('Filters', { sizingH: 'fill', gap: 10, crossAlign: 'center' }, [Chip('Видео и курсы', 'accent', { icon: 'check', height: 36, size: 13 }), Chip('Музыка', 'outline', { height: 36, size: 13 }), Spacer('h'), IconButton('star_border', { color: C.muted })]),
    T(`${count} в библиотеке`, { size: 12, w: 500, color: C.muted }),
  ];
}

function Item(icon, title, subtitle, progress, fav) {
  return H(`Media/${title}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 18, padding: [18, 24, 18, 20], gap: 18, crossAlign: 'center' }, [
    I(icon, 26, C.accent),
    V('Text', { sizingH: 'fill', gap: 6 }, [T(title, { size: 17, w: 500 }), T(subtitle, { size: 13, color: C.muted }), progress != null && ProgressBar(progress, { width: 360, height: 3 })]),
    I(fav ? 'star_rounded' : 'star_border', 24, fav ? C.accent : C.muted),
  ]);
}

const items = [
  ['school_outlined', 'Основы фотографии', 'Курс · 12 уроков · пройдено 5', 0.42, true],
  ['ondemand_video', 'Лекция о русской прозе XX века', 'Видео · 1:24:10 · осталось 38 мин', 0.55, false],
  ['library_music_outlined', 'Вечерний джаз', 'Плейлист · 24 трека', null, true],
  ['school_outlined', 'Скетчинг для начинающих', 'Курс · 8 уроков', 0, false],
  ['music_note_outlined', 'Саундтреки к чтению', 'Альбом · 14 треков', null, false],
];

const empty = DesktopScreen('Медиа — пусто', 'video', 'Медиа', ['style_outlined', 'bar_chart'], [
  Search('Поиск в медиа', { trailing: 'add_circle_outline' }),
  F('Gap', { width: 1, height: 18 }),
  ...Filters(0),
  F('Gap', { width: 1, height: 36 }),
  V('Empty', { sizingH: 'fill', fill: C.surface, cornerRadius: 24, padding: [28, 24, 28, 24], gap: 10, crossAlign: 'center' }, [
    I('perm_media', 48, C.accent),
    T('Добавьте видео или музыку', { size: 22, w: 500 }),
    T('Добавьте файлы, подключите папку с уроками или музыкой либо укажите прямую ссылку. Медиа читаются из исходных файлов.', { size: 13 }),
  ]),
], { bodyPadding: [4, 16, 20, 16] });

const filled = DesktopScreen('Медиа — библиотека', 'video', 'Медиа', ['style_outlined', 'bar_chart'], [
  Search('Поиск в медиа', { trailing: 'add_circle_outline' }),
  F('Gap', { width: 1, height: 18 }),
  ...Filters(items.length),
  F('Gap', { width: 1, height: 20 }),
  V('List', { sizingH: 'fill', gap: 12 }, items.map((i) => Item(...i))),
], { bodyPadding: [4, 16, 20, 16] });

const phone = PhoneScreen('Медиа — телефон', 'video', 'Медиа', ['style_outlined', 'bar_chart'], [
  Search('Поиск в медиа', { trailing: 'add_circle_outline' }),
  F('Gap', { width: 1, height: 14 }),
  ...Filters(items.length),
  F('Gap', { width: 1, height: 14 }),
  V('List', { sizingH: 'fill', gap: 10 }, items.map((i) => Item(...i))),
]);

module.exports = [empty, filled, phone];
