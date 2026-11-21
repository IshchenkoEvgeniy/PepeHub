// Shared building blocks of PepeHub windows: navigation rail, bottom bar,
// page header, search field, chips, buttons, covers and cards.
'use strict';
const { C, FONT, F, H, V, T, I, R, Display, Book, Spacer } = require('./lib');

const SECTIONS = [
  ['books', 'Книги', 'menu_book_outlined', 'menu_book'],
  ['audio', 'Аудиокниги', 'headphones_outlined', 'headphones'],
  ['video', 'Медиа', 'perm_media_outlined', 'perm_media'],
  ['library', 'Библиотека', 'local_library_outlined', 'local_library'],
  ['recommendations', 'Рекомендации', 'star_outline', 'star_rounded'],
  ['statistics', 'Статистика', 'bar_chart_outlined', 'bar_chart_rounded'],
];

function NavItem([key, label, icon, selectedIcon], current, vertical) {
  const sel = key === current, color = sel ? C.accent : C.muted;
  return V(`Nav/${label}`, { sizingH: 'fill', crossAlign: 'center', gap: 0, padding: [0, 2, 0, 2], height: vertical ? 64 : 76, sizingV: 'fixed' }, [
    R('Indicator', { width: vertical ? 40 : 76, height: 3, cornerRadius: 2, fill: sel ? C.accent : '#00000000' }),
    F('Gap', { width: 1, height: vertical ? 8 : 14 }),
    I(sel ? selectedIcon : icon, 22, color),
    F('Gap', { width: 1, height: 4 }),
    T(label, { size: vertical ? 10 : 11, w: sel ? 700 : 500, color, textAlign: 'center' }),
  ]);
}

/** Desktop navigation rail, 104 px wide. */
function Rail(current, settingsSelected = false) {
  return V('Rail', { width: 104, sizingH: 'fixed', sizingV: 'fill', fill: C.nav, strokeRightWeight: 1, stroke: C.line, crossAlign: 'center', padding: [22, 0, 12, 0] }, [
    T('PepeHub', { font: FONT.display, w: 700, size: 15, color: C.text }),
    F('Gap', { width: 1, height: 22 }),
    ...SECTIONS.map((s) => NavItem(s, current, false)),
    Spacer('v'),
    V('Nav/Настройки', { crossAlign: 'center', height: 64, sizingV: 'fixed', mainAlign: 'center', gap: 4 }, [
      I('tune_rounded', 22, settingsSelected ? C.accent : C.muted),
      T('Настройки', { size: 11, w: 500, color: settingsSelected ? C.accent : C.muted }),
    ]),
  ]);
}

/** Phone bottom navigation bar, 64 px. */
function BottomBar(current) {
  return H('BottomBar', { sizingH: 'fill', height: 64, sizingV: 'fixed', fill: C.nav, strokeTopWeight: 1, stroke: C.line }, SECTIONS.map((s) => NavItem(s, current, true)));
}

/** Section title row: "КНИГИ" + action icons. */
function Header(title, actions = [], { phone = false } = {}) {
  return H('Header', { sizingH: 'fill', padding: [14, 8, 6, 20], crossAlign: 'center', gap: 8 }, [
    Display(title.toUpperCase(), phone ? 30 : 36),
    Spacer('h'),
    ...actions.map((a) => IconButton(a)),
    phone && IconButton('tune_rounded'),
  ]);
}

function IconButton(icon, { color = C.text, size = 24, bg } = {}) {
  return F(`IconButton/${icon}`, { width: 48, height: 48, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center', cornerRadius: 24, ...(bg && { fill: bg }) }, [I(icon, size, color)]);
}

/** Desktop window with rail. `body` children go into a vertical column. */
function DesktopScreen(name, current, title, actions, body, { width = 1440, height = 1000, bodyGap = 0, bodyPadding = [0, 20, 20, 20] } = {}) {
  return H(name, { width, height, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true, crossAlign: 'min' }, [
    Rail(current),
    V('Content', { sizingH: 'fill', sizingV: 'fill' }, [
      Header(title, actions),
      V('Body', { sizingH: 'fill', sizingV: 'fill', padding: bodyPadding, gap: bodyGap, clip: true }, body),
    ]),
  ]);
}

/** Phone window (430×932) with bottom bar. */
function PhoneScreen(name, current, title, actions, body, { height = 932, bodyGap = 0, bodyPadding = [0, 16, 16, 16] } = {}) {
  return V(name, { width: 430, height, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
    Header(title, actions, { phone: true }),
    V('Body', { sizingH: 'fill', sizingV: 'fill', padding: bodyPadding, gap: bodyGap, clip: true }, body),
    BottomBar(current),
  ]);
}

/** Page opened above a section: back arrow + title (AppBar). */
function SubScreen(name, title, actions, body, { width = 1200, height = 1000, bodyPadding = [8, 24, 24, 24], bodyGap = 16, back = true } = {}) {
  return V(name, { width, height, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
    H('AppBar', { sizingH: 'fill', height: 56, sizingV: 'fixed', padding: [0, 8, 0, back ? 4 : 16], crossAlign: 'center', gap: 8 }, [
      back && IconButton('arrow_back'),
      Display(title, 22, C.text, { letterSpacing: 0 }),
      Spacer('h'),
      ...actions.map((a) => IconButton(a)),
    ]),
    V('Body', { sizingH: 'fill', sizingV: 'fill', padding: bodyPadding, gap: bodyGap, clip: true }, body),
  ]);
}

function Search(placeholder, { trailing, height = 52 } = {}) {
  return H('Search', { sizingH: 'fill', height, sizingV: 'fixed', fill: C.surface, cornerRadius: 26, stroke: C.line, strokeWeight: 1, padding: [0, 16, 0, 16], gap: 16, crossAlign: 'center' }, [
    I('search', 24, C.muted),
    T(placeholder, { size: 14, w: 500, color: C.muted, sizingH: 'fill', textAutoResize: 'height' }),
    trailing && I(trailing, 24, C.muted),
  ]);
}

/** Pill chip. kind: 'accent' (filled accent), 'white' (filled white), 'outline'. */
function Chip(label, kind = 'outline', { icon, size = 14, height = 34 } = {}) {
  const fill = kind === 'accent' ? C.accent : kind === 'white' ? '#ffffff' : '#00000000';
  const color = kind === 'accent' ? C.onAccent : kind === 'white' ? '#121212' : C.text;
  return H(`Chip/${label}`, { height, sizingV: 'fixed', padding: [0, 16, 0, icon ? 12 : 16], gap: 8, cornerRadius: height / 2, fill, stroke: kind === 'outline' ? C.strong : '#00000000', strokeWeight: 1, crossAlign: 'center' }, [
    icon && I(icon, 18, color),
    T(label, { size, w: kind === 'outline' ? 500 : 700, color }),
  ]);
}

/** Status badge with outline, e.g. "Читаю". */
function Badge(label, color = C.muted) {
  return H(`Badge/${label}`, { height: 26, sizingV: 'fixed', padding: [0, 8, 0, 8], cornerRadius: 6, stroke: C.strong, strokeWeight: 1, crossAlign: 'center' }, [T(label, { size: 11, w: 700, color })]);
}

function Button(label, { icon, kind = 'accent', height = 44, fillWidth = false } = {}) {
  const fill = kind === 'accent' ? C.accent : '#00000000', color = kind === 'accent' ? C.onAccent : kind === 'text' ? C.accent : C.text;
  return H(`Button/${label}`, { height, sizingV: 'fixed', ...(fillWidth && { sizingH: 'fill' }), mainAlign: 'center', padding: [0, 20, 0, icon ? 16 : 20], gap: 8, cornerRadius: height / 2, fill, stroke: kind === 'outline' ? C.strong : '#00000000', strokeWeight: 1, crossAlign: 'center' }, [
    icon && I(icon, 20, color),
    T(label, { size: 15, w: 700, color, ...(fillWidth && { sizingH: 'fill', textAutoResize: 'height', lineHeight: '120%' }) }),
  ]);
}

/** Demo cover in the style of the documentation covers. */
const COVERS = [
  ['#3e6a58', 'Архитектура привычек', 'Елена Соколова'],
  ['#7a4a40', 'Атлас тишины', 'Михаил Лесной'],
  ['#5e4a78', 'Город у моря', 'Илья Северин'],
  ['#3a4a86', 'Дорога к маяку', 'Алексей Мирный'],
  ['#8a6a3a', 'Завтра начинается сегодня', 'Мария Орлова'],
  ['#2f5868', 'Северный ветер', 'Анна Волкова'],
];
function Cover(i, width = 200, height = 290, { detail = true, radius = 4 } = {}) {
  const [color, title, author] = COVERS[i % COVERS.length], s = width / 200;
  return F(`Cover/${title}`, { width, height, fill: color, cornerRadius: radius, clip: true }, [
    { kind: 'ellipse', name: 'Glow', props: { width: 160 * s, height: 160 * s, x: 75 * s, y: -25 * s, fill: '#ffffff14' } },
    { kind: 'ellipse', name: 'Shade', props: { width: 240 * s, height: 240 * s, x: -90 * s, y: height * 0.55, fill: '#0000001f' } },
    detail && T(author.toUpperCase(), { size: Math.max(5, 7.5 * s), w: 500, color: '#efe4cbcc', x: 14 * s, y: 30 * s }),
    detail && R('Rule', { width: 172 * s, height: Math.max(1, s), x: 14 * s, y: 86 * s, fill: '#efe4cb55' }),
    detail && T(title, { font: FONT.serif, size: Math.max(6, 25 * s), w: 500, color: '#fbefda', x: 14 * s, y: 104 * s, width: 172 * s, textAutoResize: 'height', lineHeight: '115%' }),
  ]);
}

/** Placeholder cover with a book icon (no artwork). */
function CoverIcon(width = 50, height = 72, icon = 'menu_book', fill = C.raised) {
  return F('Cover/Placeholder', { width, height, fill, cornerRadius: 6, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I(icon, Math.round(width * 0.45), C.muted)]);
}

function ProgressBar(value, { width, fill = C.accent, track = C.raised, height = 4 } = {}) {
  return F('Progress', { ...(width ? { width } : { sizingH: 'fill', width: 100 }), height, fill: track, cornerRadius: height / 2, clip: true }, [
    R('Value', { width: Math.max(1, (width || 300) * value), height, fill, cornerRadius: height / 2, x: 0, y: 0 }),
  ]);
}

/** Card surface. */
function Card(name, props, children) {
  return V(name, { fill: C.surface, cornerRadius: 18, padding: 20, gap: 12, sizingH: 'fill', ...props }, children);
}

/** Tabs row like "Все 6  Читаю 2 …". */
function Tabs(items, selected = 0, { size = 18 } = {}) {
  return H('Tabs', { gap: 0, strokeBottomWeight: 1, stroke: C.line, crossAlign: 'max' }, items.map(([label, count], i) => V(`Tab/${label}`, { gap: 6, padding: [0, 16, 0, 0] }, [
    H('Label', { gap: 4, crossAlign: 'min' }, [
      T(label, { font: FONT.display, w: 700, size, color: i === selected ? C.accent : C.muted }),
      count != null && T(String(count), { size: 11, w: 500, color: i === selected ? C.accent : C.muted }),
    ]),
    R('Underline', { width: 36, height: 3, cornerRadius: 2, fill: i === selected ? C.accent : '#00000000', sizingH: 'fill' }),
  ])));
}

function SectionLabel(text) {
  return T(text.toUpperCase(), { size: 12, w: 700, color: C.muted, letterSpacing: 1.2 });
}

module.exports = { SECTIONS, Rail, BottomBar, Header, IconButton, DesktopScreen, PhoneScreen, SubScreen, Search, Chip, Badge, Button, Cover, CoverIcon, ProgressBar, Card, Tabs, SectionLabel, COVERS };
