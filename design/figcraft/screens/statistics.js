// «Статистика»: hub (annual chronicle + calendar), reading / listening
// statistics, the session journal and goals.
'use strict';
const { C, FONT, F, H, V, T, I, R, E, Book, Display, Spacer } = require('../lib');
const { DesktopScreen, SubScreen, Chip, Cover, ProgressBar, Card, SectionLabel, IconButton, Button, Search } = require('../components');

const serifTitle = (t, size = 26) => T(t, { font: FONT.serif, w: 700, size, sizingH: 'fill', textAutoResize: 'height', lineHeight: '115%' });
const DAYS = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
// Minutes per day for November 2026 (1..30), 0 = no reading.
const MINUTES = [40, 104, 88, 0, 56, 40, 104, 88, 72, 0, 40, 104, 88, 72, 56, 28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

// ---- Hub -----------------------------------------------------------------
function Stat(value, label, link) {
  return V(`Stat/${label}`, { sizingH: 'fill', padding: [26, 14, 18, 14], gap: 4, strokeRightWeight: 1, stroke: C.line }, [
    T(value, { font: FONT.serif, w: 700, size: 36 }), T(label, { size: 13, color: C.muted }), link && T(link, { size: 12, w: 500, color: C.accent }),
  ]);
}

function BookCalendar() {
  const cell = (day) => {
    const m = MINUTES[day - 1], sunday = (day % 7) === 1 && day !== 1 ? false : false;
    const red = [1, 8, 15, 22, 29].includes(day);
    return V(`Day/${day}`, { sizingH: 'fill', crossAlign: 'center', gap: 4, height: 132, sizingV: 'fixed', ...(day === 16 && { stroke: C.accent, strokeWeight: 1, cornerRadius: 6 }) }, [
      T(String(day), { size: 13, w: 500, color: red ? '#f06464' : C.text }),
      m > 0 && Cover((day * 5) % 6, 56, 80, { detail: false, radius: 2 }),
      m > 0 && T(m >= 60 ? `${Math.floor(m / 60)} ч ${m % 60} мин` : `${m} мин`, { size: 11, w: 500 }),
    ]);
  };
  const weeks = [[null, null, null, null, null, null, 1], [2, 3, 4, 5, 6, 7, 8], [9, 10, 11, 12, 13, 14, 15], [16, 17, 18, 19, 20, 21, 22]];
  return V('BookCalendar', { sizingH: 'fill', gap: 12 }, [
    T('Книжный календарь', { font: FONT.serif, w: 700, size: 30, fontStyle: 'Bold Italic' }),
    H('Month', { sizingH: 'fill', crossAlign: 'center' }, [T('Ноябрь 2026', { size: 22, w: 500, sizingH: 'fill' }), IconButton('chevron_left', { color: C.muted }), IconButton('chevron_right', { color: C.muted })]),
    T('Дней с книгой: 14 · выберите день, чтобы увидеть подробности', { size: 13, w: 500 }),
    H('Weekdays', { sizingH: 'fill' }, DAYS.map((d, i) => T(d, { size: 13, color: i === 6 ? '#f06464' : C.muted, sizingH: 'fill', textAlign: 'center' }))),
    ...weeks.map((w, i) => H(`Week/${i + 1}`, { sizingH: 'fill', gap: 8 }, w.map((d) => (d ? cell(d) : F('Empty', { sizingH: 'fill', width: 10, height: 10 }))))),
  ]);
}

const hub = DesktopScreen('Статистика — летопись', 'statistics', 'Статистика', ['import_export', 'refresh'], [
  H('Scope', { gap: 8 }, [Chip('Всё', 'white', { height: 36 }), Chip('Книги', 'outline', { height: 36 }), Chip('Аудио', 'outline', { height: 36 })]),
  H('Year', { sizingH: 'fill', crossAlign: 'center', padding: [16, 0, 8, 0] }, [T('Летопись 2026 года', { font: FONT.serif, size: 20, fontStyle: 'Italic', color: C.muted, sizingH: 'fill' }), IconButton('chevron_left', { color: C.muted }), IconButton('chevron_right', { color: C.muted })]),
  V('Stats', { sizingH: 'fill', strokeTopWeight: 1, stroke: C.accent }, [
    H('Row1', { sizingH: 'fill', strokeBottomWeight: 1, stroke: C.line }, [Stat('3', 'завершено · 2 кн., 1 ауд.'), Stat('26 ч', 'всего за год'), Stat('24', 'цель на год', 'Изменить цель')]),
    H('Row2', { sizingH: 'fill', strokeBottomWeight: 1, stroke: C.line }, [Stat('24', 'дня с книгой'), Stat('5', 'дней подряд', 'рекорд года 5'), Stat('0.3', 'завершений в месяц')]),
  ]),
  F('Gap', { width: 1, height: 28 }),
  BookCalendar(),
]);

// ---- Reading / listening statistics ---------------------------------------
const PERIODS = ['1 день', '7 дней', '30 дней', '365 дней', 'Всё время', 'Произвольный'];
const BARS = [0, 0, 0.55, 0.45, 0.35, 0, 0.7, 0.55, 0.45, 0.35, 1, 0, 0.55, 0.45, 0.35, 1, 0.85, 0, 0.45, 0.35, 1, 0.85, 0.7, 0, 0.35, 1, 0.85, 0.7, 0.45, 0.05];

function Streak() {
  return H('Streak', { gap: 3 }, BARS.map((b, i) => R(`D${i}`, { width: 7, height: 28, cornerRadius: 3, fill: b === 0 ? C.raised : b > 0.5 ? C.accent : '#a0a0a0' })));
}

function Bars() {
  return F('Chart', { width: 784, height: 220 }, [
    ...BARS.map((b, i) => R(`Bar ${i + 1}`, { width: 18, height: Math.max(3, 210 * b), x: 4 + i * 26, y: 220 - Math.max(3, 210 * b), fill: b > 0.5 ? C.accent : b === 0 ? C.raised : '#a0a0a0', cornerRadius: [2, 2, 0, 0] })),
    R('Goal line', { width: 780, height: 2, x: 0, y: 64, fill: '#ffffff00', strokes: ['#a0a0a0'], strokeWeight: 1, dashes: [6, 4] }),
  ]);
}

function MonthCalendar() {
  const day = (d) => {
    const m = MINUTES[d - 1], future = d > 16;
    const fill = d === 16 ? '#00000000' : m >= 80 ? C.accent : m >= 40 ? '#2a5bd0' : m > 0 ? '#2448a6' : '#00000000';
    return F(`Day/${d}`, { width: 50, height: 50, cornerRadius: 8, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center', fill, ...(m === 0 && !future && d !== 16 && { stroke: C.line, strokeWeight: 1 }), ...(d === 16 && { stroke: C.accentSoft, strokeWeight: 2 }) }, [T(String(d), { size: 14, w: m > 0 ? 700 : 400, color: future ? '#5a5a5a' : C.text })]);
  };
  const weeks = [[0, 0, 0, 0, 0, 0, 1], [2, 3, 4, 5, 6, 7, 8], [9, 10, 11, 12, 13, 14, 15], [16, 17, 18, 19, 20, 21, 22], [23, 24, 25, 26, 27, 28, 29], [30, 0, 0, 0, 0, 0, 0]];
  return Card('Calendar', { width: 420, sizingH: 'fixed', cornerRadius: 24, padding: [22, 20, 22, 20], gap: 6 }, [
    H('Head', { sizingH: 'fill' }, [serifTitle('Календарь · ноябрь 2026', 26), IconButton('chevron_left', { color: C.muted }), IconButton('chevron_right', { color: C.muted })]),
    H('Weekdays', { sizingH: 'fill', gap: 4 }, DAYS.map((d) => T(d, { size: 11, color: C.muted, width: 50, textAlign: 'center', textAutoResize: 'height' }))),
    ...weeks.map((w, i) => H(`Week ${i + 1}`, { gap: 4 }, w.map((d) => (d ? day(d) : F('Empty', { width: 50, height: 50 }))))),
    H('Legend', { sizingH: 'fill', gap: 8, crossAlign: 'center', padding: [8, 0, 0, 0] }, [T('Меньше', { size: 11, color: C.muted }), R('Scale', { width: 180, height: 6, cornerRadius: 3, fills: [{ type: 'linearGradient', stops: ['#1c2b4a', C.accent] }], sizingH: 'fill' }), T('Больше · 52 мин', { size: 11, color: C.muted })]),
  ]);
}

function ActivityStats(name, title, { audio = false } = {}) {
  const highlight = V('Total', { sizingH: 'fill', fill: C.accent, cornerRadius: 24, padding: [18, 20, 20, 20], gap: 4 }, [
    T(audio ? 'ВРЕМЯ ДЛЯ ИСТОРИЙ · ЗА 30 ДНЕЙ' : 'ЗА 30 ДНЕЙ', { size: 11, w: 700, color: '#dbe6ff', letterSpacing: 1 }),
    Display('13 ч 24 мин', 40),
    !audio && T('Активное чтение · аудио не учитывается', { size: 12, color: '#dbe6ff' }),
    H('Numbers', { gap: 28, padding: [8, 0, 0, 0] }, [
      ['23', 'Сессий за период'], ['23', 'Активных дней'], audio ? ['1.25×', 'Средняя скорость'] : ['34 мин', 'Средняя сессия'],
    ].map(([v, l]) => V(l, { gap: 0 }, [Display(v, 22), T(l, { size: 12, color: '#dbe6ff' })]))),
  ]);
  const goal = Card('Goal', { width: 300, sizingH: 'fixed', cornerRadius: 22 }, audio ? [
    H('Head', { sizingH: 'fill' }, [serifTitle('Мои цели · все книги'), I('tune', 22, C.muted)]),
    H('Today', { sizingH: 'fill' }, [T('Сегодня', { size: 13, w: 700, sizingH: 'fill' }), T('0 с / 30 мин', { size: 13, color: C.muted })]),
    ProgressBar(0, { width: 260, height: 8 }),
    H('Week', { sizingH: 'fill' }, [T('Неделя с понедельника', { size: 13, w: 700, sizingH: 'fill' }), T('0 с / 180 мин', { size: 13, color: C.muted })]),
    ProgressBar(0, { width: 260, height: 8 }),
  ] : [
    H('Head', { sizingH: 'fill' }, [serifTitle('Цель на сегодня · вся библиотека'), I('tune', 22, C.muted)]),
    H('Ring', { gap: 14, crossAlign: 'center' }, [
      F('Ring', { width: 116, height: 116 }, [
        E('Track', { width: 116, height: 116, x: 0, y: 0, fills: [], stroke: C.raised, strokeWeight: 10 }),
        V('Value', { x: 0, y: 34, width: 116, sizingH: 'fixed', crossAlign: 'center' }, [Display('0', 30), T('из 30 мин', { size: 11, color: C.muted })]),
      ]),
      V('Text', { width: 130, sizingH: 'fixed', gap: 6 }, [T('Осталось 30 мин', { size: 14, w: 700, sizingH: 'fill', textAutoResize: 'height' }), T('Считается всё чтение за сегодня, по всем книгам.', { size: 12, color: C.muted, sizingH: 'fill', textAutoResize: 'height' })]),
    ]),
  ]);
  const streak = Card('Streak', { width: 300, sizingH: 'fixed', cornerRadius: 22 }, [
    serifTitle(audio ? 'Текущая серия' : 'Дней подряд / рекорд'),
    H('Value', { gap: 10, crossAlign: 'max' }, [Display('5', 46), T(audio ? 'лучшая серия дней: 5' : 'рекорд 5', { size: 14, color: C.muted })]),
    Streak(),
    T('последние 30 дней · день серии: от 5 минут', { size: 11, color: C.muted }),
  ]);
  return DesktopScreen(name, 'statistics', title, audio ? ['info_outline', 'edit_note', 'file_download_outlined', 'refresh'] : ['info_outline', 'edit_note', 'refresh'], [
    H('Periods', { gap: 8 }, [...PERIODS.map((p, i) => Chip(p, i === 2 ? 'white' : 'outline', { height: 36 })), audio && Chip('Все книги', 'outline', { icon: 'menu_book', height: 48 })]),
    F('Gap', { width: 1, height: 18 }),
    H('Top', { sizingH: 'fill', gap: 16 }, [goal, streak, highlight]),
    F('Gap', { width: 1, height: 18 }),
    H('Middle', { sizingH: 'fill', gap: 16 }, [
      Card('Days', { cornerRadius: 22, gap: 14 }, [H('Head', { sizingH: 'fill' }, [serifTitle('По дням'), T('- - цель 30 мин', { size: 12, color: C.muted })]), Bars(), H('Axis', { sizingH: 'fill', mainAlign: 'spaceBetween' }, [T('18 октября', { size: 11, color: C.muted }), T('сегодня', { size: 11, color: C.muted })])]),
      MonthCalendar(),
    ]),
    F('Gap', { width: 1, height: 18 }),
    H('Bottom', { sizingH: 'fill', gap: 16 }, [
      Card('Books', { cornerRadius: 22 }, [serifTitle(audio ? 'Книги' : 'По книгам'), ...[[1, 'Атлас тишины', '3 ч 0 мин'], [0, 'Архитектура привычек', '3 ч 0 мин']].map(([c, t, v]) => H(`Book/${t}`, { sizingH: 'fill', gap: 14, crossAlign: 'center', strokeTopWeight: 1, stroke: C.line, padding: [10, 0, 0, 0] }, [Cover(c, 34, 50, { detail: false, radius: 3 }), V('T', { sizingH: 'fill', gap: 6 }, [Book(t, 18), ProgressBar(0.22, { width: 440, height: 4 })]), V('V', { crossAlign: 'max' }, [T(v, { size: 13, w: 700 }), T('22%', { size: 11, color: C.muted })])]))]),
      Card('Compare', { width: 372, sizingH: 'fixed', cornerRadius: 22 }, [serifTitle('Сравнение периодов'), T('С предыдущим периодом такой же длины.', { size: 12, color: C.muted }), H('Row', { sizingH: 'fill', crossAlign: 'center' }, [V('T', { sizingH: 'fill' }, [T(audio ? 'Время прослушивания' : 'Время чтения', { size: 15, w: 500 }), T('13 ч 24 мин · раньше 11 ч 10 мин', { size: 12 })]), T('+20%', { size: 16, w: 700 })])]),
    ]),
  ], { bodyPadding: [6, 28, 20, 28] });
}

// ---- Session journal (StatisticsManagementPage) ----------------------------
const journal = SubScreen('Журнал — правка сессий', 'Журнал · правка сессий', ['select_all', 'copy_all_outlined', 'refresh'], [
  H('Tabs', { sizingH: 'fill', strokeBottomWeight: 1, stroke: C.line }, [
    V('Tab/Чтение', { sizingH: 'fill', crossAlign: 'center', gap: 4, padding: [8, 0, 0, 0] }, [I('menu_book', 24, C.accent), T('Чтение', { size: 13, w: 500, color: C.accent }), R('Underline', { width: 50, height: 3, fill: C.accent, cornerRadius: 2 })]),
    V('Tab/Прослушивание', { sizingH: 'fill', crossAlign: 'center', gap: 4, padding: [8, 0, 0, 0] }, [I('headphones', 24, C.muted), T('Прослушивание', { size: 13, w: 500, color: C.muted }), R('Pad', { width: 50, height: 3, fill: '#00000000' })]),
  ]),
  Search('Поиск по книге, дате или типу записи'),
  H('Filters', { gap: 24, crossAlign: 'center' }, [H('Book', { gap: 6, crossAlign: 'center', width: 200, sizingH: 'fixed' }, [I('menu_book', 18, C.accent), T('Все книги', { size: 14, w: 500, color: C.accent })]), H('Kind', { gap: 4, strokeBottomWeight: 1, stroke: C.muted, padding: [0, 0, 6, 0] }, [T('Все записи', { size: 15, w: 500 }), I('arrow_drop_down', 22)]), H('Range', { gap: 4, strokeBottomWeight: 1, stroke: C.muted, padding: [0, 0, 6, 0] }, [T('Всё время', { size: 15, w: 500 }), I('arrow_drop_down', 22)]), I('arrow_downward', 22, C.muted)]),
  T('Загружено: 23 · 13 ч 24 мин · 0 знаков', { size: 12, w: 700 }),
  V('Days', { sizingH: 'fill', gap: 0 }, [[15, 28], [14, 36], [13, 44], [12, 52], [11, 20], [9, 36], [8, 44], [7, 52]].map(([d, m]) => H(`Day/${d}`, { sizingH: 'fill', height: 72, sizingV: 'fixed', crossAlign: 'center', gap: 24, padding: [0, 16, 0, 8] }, [I('expand_more', 24, C.muted), V('T', { sizingH: 'fill' }, [T(`2026-11-${String(d).padStart(2, '0')}`, { size: 17 }), T(`1 записей · ${m} мин`, { size: 13, w: 500 })]), I('check_box_outline_blank', 24, C.muted)]))),
  F('FabRow', { sizingH: 'fill', width: 10, height: 56, layout: 'horizontal', mainAlign: 'max' }, [Button('Добавить чтение', { icon: 'add', height: 56 })]),
], { bodyPadding: [0, 12, 12, 12], bodyGap: 12 });

// ---- Goals and reminders (GoalSettingsPage) --------------------------------
function Toggle(on = false) {
  return F('Switch', { width: 52, height: 32, cornerRadius: 16, fill: on ? C.accent : C.raised, stroke: C.strong, strokeWeight: 2 }, [E('Knob', { width: 16, height: 16, x: on ? 28 : 8, y: 8, fill: on ? '#ffffff' : '#a0a0a0' })]);
}
function GoalGroup(title, value, options, selected) {
  return V(title, { sizingH: 'fill', padding: [20, 16, 20, 16], gap: 14, strokeBottomWeight: 1, stroke: C.line }, [
    H('Head', { sizingH: 'fill' }, [T(title, { size: 14, w: 700, sizingH: 'fill' }), T(value, { size: 14, w: 500 })]),
    H('Options', { gap: 8 }, options.map((o, i) => Chip(o, i === selected ? 'accent' : 'outline', { icon: i === selected ? 'check' : null, height: 34, size: 13 }))),
  ]);
}
const settingRow = (title, trailing, sub, dim) => H(title, { sizingH: 'fill', padding: [18, 28, 18, 16], crossAlign: 'center', gap: 12, strokeBottomWeight: 1, stroke: C.line }, [V('T', { sizingH: 'fill', gap: 2 }, [T(title, { size: 16, color: dim ? C.muted : C.text }), sub && T(sub, { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height' })]), trailing]);

const goals = SubScreen('Цели и напоминания', 'Цели и напоминания', [], [
  V('Column', { sizingH: 'fill', padding: [16, 240, 0, 240], gap: 14 }, [
    T('Цели и напоминания', { size: 26, w: 700 }),
    T('Дневные и недельные цели и ежедневное напоминание о них.', { size: 13, color: C.muted }),
    SectionLabel('Цели'),
    V('Goals', { sizingH: 'fill', fill: C.surface, cornerRadius: 16, stroke: C.line, strokeWeight: 1, clip: true }, [
      GoalGroup('Чтение в день', '30 мин', ['Без цели', '15 мин', '30 мин', '1 ч', '1 ч 30 мин', 'Своё…'], 2),
      GoalGroup('Аудиокниги в день', '30 мин', ['Без цели', '15 мин', '30 мин', '1 ч', '1 ч 30 мин', 'Своё…'], 2),
      GoalGroup('Аудиокниги в неделю', '3 ч', ['Без цели', '2 ч', '3 ч', '5 ч', '7 ч', 'Своё…'], 2),
    ]),
    T('Цели общие для всех книг. Музыка не учитывается в цели аудиокниг.', { size: 13, color: C.muted }),
    SectionLabel('Напоминание'),
    V('Reminder', { sizingH: 'fill', fill: C.surface, cornerRadius: 16, stroke: C.line, strokeWeight: 1, clip: true }, [
      settingRow('Напоминать о чтении и аудиокнигах', Toggle(true)),
      settingRow('Время напоминания', T('20:00', { size: 13, w: 500, color: C.muted })),
      settingRow('О ежедневных целях', I('check_box', 24, C.accent)),
      settingRow('О планах чтения', I('check_box', 24, C.accent)),
      settingRow('Системные уведомления', Toggle(false), 'Приходят и при закрытом приложении. Windows показывает уведомление после входа в учётную запись, в том числе после выхода из сна.'),
    ]),
  ]),
]);

module.exports = [hub, ActivityStats('Статистика — чтение', 'Чтение'), ActivityStats('Статистика — прослушивание', 'Прослушивание', { audio: true }), journal, goals];
module.exports.Toggle = Toggle;
module.exports.settingRow = settingRow;
