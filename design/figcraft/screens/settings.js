// «Настройки»: sections list + content pane; Library data and folders.
'use strict';
const { C, FONT, F, H, V, T, I, R, Book, Display, Spacer } = require('../lib');
const { DesktopScreen, PhoneScreen, SubScreen, Search, Chip, Badge, Button, Card, SectionLabel, IconButton, ProgressBar } = require('../components');
const { Toggle } = require('./statistics');

const NAV = [
  ['Основные', [['palette_outlined', 'Интерфейс'], ['menu_book_outlined', 'Чтение и аудио']]],
  ['Данные', [['folder_outlined', 'Библиотека и файлы'], ['cloud_upload_outlined', 'Резервные копии и экспорт'], ['storage', 'Хранилище']]],
  ['Приложение', [['info_outline', 'О приложении'], ['help_outline', 'Диагностика и справка']]],
];

function SettingsNav(selected) {
  return V('Sections', { width: 260, sizingH: 'fixed', sizingV: 'fill', fill: '#181818', padding: [12, 12, 12, 12], gap: 4 }, [
    Search('Поиск настроек'),
    ...NAV.map(([group, items]) => V(`Group/${group}`, { sizingH: 'fill', gap: 2, padding: [14, 0, 0, 0] }, [
      F('Label', { padding: [0, 0, 6, 4], layout: 'horizontal', sizingH: 'hug', sizingV: 'hug' }, [SectionLabel(group)]),
      ...items.map(([icon, label]) => H(`Item/${label}`, { sizingH: 'fill', height: 56, sizingV: 'fixed', padding: [0, 12, 0, 16], gap: 16, crossAlign: 'center', cornerRadius: 14, ...(label === selected && { fill: C.selected }) }, [I(icon, 22, label === selected ? C.accent : C.muted), T(label, { size: 15, color: label === selected ? C.accent : C.text, sizingH: 'fill', textAutoResize: 'height' })])),
    ])),
  ]);
}

function SettingsWindow(name, selected, content) {
  return V(name, { width: 1200, height: 1000, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
    H('AppBar', { sizingH: 'fill', height: 56, sizingV: 'fixed', padding: [0, 16, 0, 4], gap: 16, crossAlign: 'center', fill: '#181818' }, [IconButton('arrow_back'), Display('Настройки', 22, C.text, { letterSpacing: 0 })]),
    H('Main', { sizingH: 'fill', sizingV: 'fill' }, [SettingsNav(selected), V('Content', { sizingH: 'fill', sizingV: 'fill', padding: [28, 40, 24, 40], gap: 16, clip: true }, content)]),
  ]);
}

const head = (title, text) => [T(title, { size: 26, w: 700 }), T(text, { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height' })];
const group = (rows) => V('Group', { sizingH: 'fill', fill: C.surface, cornerRadius: 16, stroke: C.line, strokeWeight: 1, clip: true }, rows);
const row = (title, sub, trailing, last) => H(`Row/${title}`, { sizingH: 'fill', padding: [14, 20, 14, 20], gap: 12, crossAlign: 'center', ...(!last && { strokeBottomWeight: 1, stroke: C.line }) }, [V('T', { sizingH: 'fill', gap: 2 }, [T(title, { size: 15 }), sub && T(sub, { size: 12, color: C.muted, sizingH: 'fill', textAutoResize: 'height' })]), trailing]);
const value = (t) => H('Value', { gap: 4, crossAlign: 'center' }, [T(t, { size: 13, w: 500, color: C.muted }), I('chevron_right', 20, C.muted)]);

// Theme tile with a tiny preview of the palette.
const THEMES = [
  ['Бумага', '#f6f1e7', '#fffbf4', '#2a2118', '#a8481f'], ['День', '#f3f5f9', '#ffffff', '#1a1f2b', '#2a56c6'],
  ['Сумерки', '#111a2b', '#18233a', '#eef0f5', '#f2a36b'], ['Угли', '#140e0a', '#20160f', '#f7ece2', '#ff8a3d'], ['Хвоя', '#0f1d1b', '#162a27', '#e9f0ec', '#e39a62'], ['Латунь', '#0b1020', '#131a2e', '#ece6d8', '#d9b46a'], ['Слива', '#1a1420', '#241c2c', '#f3ecef', '#f4a98a'],
  ['Чёрно-белый', '#000000', '#141414', '#ffffff', '#ffffff'], ['Синий', '#121212', '#1e1e1e', '#ffffff', '#2f6fed'], ['Красный', '#121212', '#1e1e1e', '#ffffff', '#d93636'], ['Зелёный', '#121212', '#1e1e1e', '#ffffff', '#30c75a'], ['Жёлтый', '#121212', '#1e1e1e', '#ffffff', '#ffd400'],
];
function ThemeTile([name, bg, surface, text, accent]) {
  const sel = name === 'Синий';
  return V(`Theme/${name}`, { width: 160, sizingH: 'fixed', fill: bg, cornerRadius: 14, padding: 10, gap: 10, stroke: sel ? C.accent : '#ffffff22', strokeWeight: sel ? 2 : 1 }, [
    V('Preview', { sizingH: 'fill', fill: surface, cornerRadius: 8, padding: [10, 10, 10, 10], gap: 5 }, [R('Line1', { width: 46, height: 5, cornerRadius: 3, fill: text }), R('Line2', { width: 30, height: 3, cornerRadius: 2, fill: text + '99' }), H('Bottom', { sizingH: 'fill', crossAlign: 'center' }, [R('Accent', { width: 34, height: 11, cornerRadius: 6, fill: accent }), Spacer('h'), sel && I('check_circle', 14, C.accent)])]),
    T(name, { size: 13, w: 700, color: text }),
  ]);
}

const interfaceSection = SettingsWindow('Настройки — интерфейс', 'Интерфейс', [
  ...head('Интерфейс', 'Цвета и размер элементов приложения. Шрифт и поля книги настраиваются в читалке.'),
  V('Preview', { sizingH: 'fill', cornerRadius: 16, stroke: C.line, strokeWeight: 1, padding: [16, 16, 16, 16], gap: 10 }, [
    H('Head', { sizingH: 'fill', crossAlign: 'center' }, [Display('КНИГИ', 24), Spacer('h'), Chip('Читаю', 'accent', { height: 24, size: 11 })]),
    ...[['#2f7a73', 'Северный ветер', 'Анна Белова', 0.62], ['#8a6a50', 'Дом у реки', 'Пётр Лунин', 0.18]].map(([c, t, a, p], i) => H(`Book ${i + 1}`, { sizingH: 'fill', gap: 12, crossAlign: 'center', ...(i === 0 && { strokeBottomWeight: 1, stroke: C.line, padding: [0, 0, 10, 0] }) }, [R('Cover', { width: 34, height: 48, cornerRadius: 4, fill: c }), V('T', { sizingH: 'fill', gap: 2 }, [Book(t, 16), T(a, { size: 11, color: C.muted }), ProgressBar(p, { width: 780, height: 2 })])])),
  ]),
  SectionLabel('Тема'),
  group([row('Как в системе', 'Светлая палитра днём, тёмная ночью', Toggle(false), true)]),
  T('Светлые', { size: 13, w: 500, color: C.muted }),
  H('Light', { gap: 12 }, THEMES.slice(0, 2).map(ThemeTile)),
  T('Тёмные', { size: 13, w: 500, color: C.muted }),
  H('Dark1', { gap: 12 }, THEMES.slice(2, 7).map(ThemeTile)),
  H('Dark2', { gap: 12 }, THEMES.slice(7).map(ThemeTile)),
  SectionLabel('Текст и движение'),
  group([row('Размер текста интерфейса: 100%', null, T('A  A', { size: 14, color: C.muted })), row('Компактный интерфейс', 'Меньше отступов в списках', Toggle(false)), row('Уменьшить анимации', null, Toggle(false), true)]),
]);

const readingSection = SettingsWindow('Настройки — чтение и аудио', 'Чтение и аудио', [
  ...head('Чтение и аудио', 'Читалка, плеер аудиокниг, цели и напоминания.'),
  SectionLabel('Читалка'),
  group([row('Настройки читалки', 'Шрифт, размер, поля, тема страницы', value('Lora · 22'), true)]),
  SectionLabel('Плеер аудиокниг'),
  group([
    row('Скорость для новых книг', null, H('Speeds', { gap: 6 }, ['0.8×', '1×', '1.25×', '1.5×', '2×'].map((s) => Chip(s, s === '1.25×' ? 'accent' : 'outline', { height: 30, size: 12 })))),
    row('Шаг перемотки', 'Назад и вперёд', H('Steps', { gap: 6 }, [Chip('Назад 10 с', 'outline', { height: 30, size: 12 }), Chip('Вперёд 30 с', 'outline', { height: 30, size: 12 })])),
    row('Возврат после паузы и таймера', 'Отмотать немного назад, чтобы вспомнить контекст', value('10 с')),
    row('Плавно затихать перед сном', null, Toggle(true)),
    row('Продолжать после звонка', null, Toggle(false), true),
  ]),
  SectionLabel('Цели'),
  group([row('Цели чтения и прослушивания', 'Минут в день и в неделю', value('30 мин в день')), row('Напоминания', null, value('20:00'), true)]),
]);

const filesSection = SettingsWindow('Настройки — библиотека и файлы', 'Библиотека и файлы', [
  ...head('Библиотека и файлы', 'Откуда приложение берёт книги и аудио и что делать с недоступными файлами.'),
  group([
    row('Папки книг', 'Источники текстовой библиотеки · 2 папки', value('')),
    row('Папки аудиокниг', 'Источники аудиобиблиотеки · 1 папка', value('')),
    row('Папка добавленных книг', 'Куда копировать книги, открытые по одной', value('')),
    row('Скрытые и недоступные', 'Скрытые, без файла и корзина', value('3'), true),
  ]),
  SectionLabel('Рекомендации'),
  group([row('Источники рекомендаций', 'Open Library, Google Books', value(''), true)]),
]);

const phone = V('Настройки — телефон', { width: 430, height: 932, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
  H('AppBar', { sizingH: 'fill', height: 56, sizingV: 'fixed', padding: [0, 16, 0, 4], gap: 12, crossAlign: 'center' }, [IconButton('arrow_back'), Display('Настройки', 22, C.text, { letterSpacing: 0 })]),
  V('Body', { sizingH: 'fill', padding: [4, 12, 12, 12], gap: 4 }, [
    Search('Поиск настроек'),
    ...NAV.map(([g, items]) => V(`Group/${g}`, { sizingH: 'fill', gap: 2, padding: [12, 0, 0, 0] }, [
      F('Label', { padding: [0, 0, 6, 4], layout: 'horizontal', sizingH: 'hug', sizingV: 'hug' }, [SectionLabel(g)]),
      ...items.map(([icon, label]) => H(`Item/${label}`, { sizingH: 'fill', height: 56, sizingV: 'fixed', padding: [0, 12, 0, 16], gap: 16, crossAlign: 'center' }, [I(icon, 22, C.muted), T(label, { size: 15, sizingH: 'fill' }), I('chevron_right', 20, C.muted)])),
    ])),
  ]),
]);

// Library data (sync folder, backups, export).
const libraryData = DesktopScreen('Данные библиотеки', 'library', 'Данные библиотеки', [], [
  T('Папка для синхронизации между устройствами, резервные копии и экспорт.', { size: 13, color: C.muted }),
  F('Gap', { width: 1, height: 20 }),
  V('Folder', { sizingH: 'fill', fill: C.surface, cornerRadius: 24, padding: [28, 24, 24, 24], gap: 12, crossAlign: 'center' }, [
    I('folder_shared_outlined', 40, C.muted), T('Папка библиотеки', { size: 18, w: 700 }),
    T('Сейчас библиотека хранится только на этом устройстве. Выберите папку, которую синхронизирует Syncthing или облачный диск, — и карточки, серии, цитаты, история и обложки будут одинаковыми на телефоне и ПК.', { size: 13, color: C.muted, textAlign: 'center', sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }),
    Button('Выбрать папку…', { icon: 'create_new_folder_outlined' }),
  ]),
  F('Gap', { width: 1, height: 12 }),
  H('Syncthing', { sizingH: 'fill', fill: C.surface, cornerRadius: 20, padding: [20, 20, 20, 20], crossAlign: 'center' }, [T('Как синхронизировать с ПК через Syncthing', { size: 15, w: 700, sizingH: 'fill' }), I('expand_more', 24, C.muted)]),
  F('Gap', { width: 1, height: 16 }),
  H('Cards', { sizingH: 'fill', gap: 16 }, [
    Card('Backups', { cornerRadius: 22, gap: 14 }, [T('Резервные копии', { font: FONT.serif, w: 700, size: 26 }), T('ZIP с карточками, сериями, коллекциями, цитатами, историей, корзиной и обложками. Файлы книг и аудио в копию не входят.', { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }), H('Actions', { gap: 8 }, [Button('Создать резервную копию', { icon: 'backup_outlined' }), Button('Восстановить из файла…', { icon: 'history', kind: 'outline' })]), T('Последняя копия: 14 ноября, 22:10 · 3,2 МБ', { size: 13, w: 700 })]),
    Card('Export', { width: 420, sizingH: 'fixed', cornerRadius: 22, gap: 14 }, [T('Экспорт', { font: FONT.serif, w: 700, size: 26 }), T('Карточки без корзины: JSON — для обработки, CSV — для таблиц, Markdown — для чтения.', { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }), H('Formats', { gap: 8 }, ['JSON', 'CSV', 'Markdown'].map((f) => Button(f, { kind: 'outline' })))]),
  ]),
], { bodyPadding: [0, 28, 20, 28] });

// Book folders (ReadingRootsPage) with connected folders.
const roots = DesktopScreen('Папки книг', 'books', 'Папки книг', ['create_new_folder_outlined'], [
  V('Folders', { sizingH: 'fill', fill: C.surface, cornerRadius: 24, padding: [10, 0, 10, 0] }, [
    ...[['D:\\Книги', '214 книг · обновлено сегодня в 09:12'], ['C:\\Users\\Пользователь\\Downloads\\EPUB', '37 книг · обновлено вчера']].map(([p, s], i) => H(`Folder ${i + 1}`, { sizingH: 'fill', padding: [14, 16, 14, 20], gap: 16, crossAlign: 'center', ...(i === 0 && { strokeBottomWeight: 1, stroke: C.line }) }, [I('folder_open_outlined', 26, C.accent), V('T', { sizingH: 'fill', gap: 2 }, [T(p, { size: 15, w: 500 }), T(s, { size: 12, color: C.muted })]), IconButton('sync', { color: C.muted }), IconButton('more_vert', { color: C.muted })])),
  ]),
  F('Gap', { width: 1, height: 16 }),
  V('Import', { sizingH: 'fill', fill: C.surface, cornerRadius: 24, padding: [22, 20, 22, 20], gap: 14 }, [
    T('Импорт', { font: FONT.serif, w: 700, size: 26 }),
    H('Row', { sizingH: 'fill', gap: 20, crossAlign: 'center' }, [I('download', 24, C.muted), V('T', { sizingH: 'fill', gap: 2 }, [T('Папка добавленных книг', { size: 16 }), T('Куда копировать книги, открытые по одной через «Открыть файл…»', { size: 13 })]), I('chevron_right', 22, C.muted)]),
  ]),
], { bodyPadding: [4, 28, 20, 28] });

module.exports = [interfaceSection, readingSection, filesSection, phone, libraryData, roots];
