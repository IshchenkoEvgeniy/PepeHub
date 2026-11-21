// «Аудиокниги»: shelf and the player.
'use strict';
const { C, FONT, F, H, V, T, I, R, E, Book, Display, Spacer } = require('../lib');
const { Rail, Header, Chip, Cover, BottomBar, IconButton } = require('../components');
const { audioDesktop } = require('./books');

const CHAPTERS = ['Набережная', 'Старый маяк', 'Письмо', 'Путь домой'];

function Slider(value, width, { thumb = 20, height = 6 } = {}) {
  return F('Slider', { width, height: thumb, sizingH: 'fixed' }, [
    R('Track', { width, height, y: (thumb - height) / 2, x: 0, cornerRadius: height / 2, fill: C.raised }),
    R('Value', { width: width * value, height, y: (thumb - height) / 2, x: 0, cornerRadius: height / 2, fill: C.accent }),
    E('Thumb', { width: thumb, height: thumb, x: width * value - thumb / 2, y: 0, fill: C.accent }),
  ]);
}

function Control(icon, label, size = 30) {
  return V(`Control/${label || icon}`, { crossAlign: 'center', gap: 2, width: 52, sizingH: 'fixed' }, [I(icon, size, C.text), label && T(label, { size: 11, w: 500 })]);
}

function ChaptersPanel(width) {
  return V('Chapters', { width, sizingH: 'fixed', sizingV: 'fill', fill: C.surface, cornerRadius: 24, clip: true }, [
    H('Tabs', { sizingH: 'fill', strokeBottomWeight: 1, stroke: C.line, padding: [16, 24, 0, 24], mainAlign: 'spaceBetween' }, [
      V('Tab/Главы', { gap: 10, crossAlign: 'center' }, [T('Главы · 8', { size: 14, w: 500, color: C.accent }), R('Underline', { width: 60, height: 3, cornerRadius: 2, fill: C.accent })]),
      V('Tab/Закладки', { gap: 10 }, [T('Закладки', { size: 14, w: 500, color: C.muted }), R('Pad', { width: 1, height: 3, fill: '#00000000' })]),
      V('Tab/Перемотки', { gap: 10 }, [T('Перемотки', { size: 14, w: 500, color: C.muted }), R('Pad', { width: 1, height: 3, fill: '#00000000' })]),
    ]),
    F('Gap', { width: 1, height: 8 }),
    ...Array.from({ length: 8 }, (_, i) => H(`Chapter/${i + 1}`, { sizingH: 'fill', height: 48, sizingV: 'fixed', padding: [0, 24, 0, 16], gap: 28, crossAlign: 'center', ...(i === 1 && { fill: C.selected, cornerRadius: 12 }) }, [
      T(String(i + 1), { font: FONT.display, w: 700, size: 18, color: i === 1 ? C.accent : C.muted }),
      T(`Глава ${i + 1}. ${CHAPTERS[i % 4]}`, { size: 13, w: 500, color: i === 1 ? C.accent : C.text, sizingH: 'fill' }),
      T('45:00', { size: 13, color: C.muted }),
    ])),
  ]);
}

function PlayerBody(phone) {
  const coverW = phone ? 180 : 302, coverH = phone ? 250 : 420;
  const info = V('Info', { sizingH: phone ? 'fill' : 'fixed', width: 305, gap: phone ? 10 : 14 }, [
    Book('Северный ветер', 30),
    T('Глава 2 из 8 · Глава 2. Старый маяк', { size: 13, color: C.muted }),
    V('BookProgress', { sizingH: 'fill', fill: C.surface, cornerRadius: 20, padding: [16, 16, 14, 16], gap: 14 }, [
      H('Line', { gap: 12 }, [T('Вся книга · 17.6%', { size: 12, w: 700 }), T('Осталось 3:57:17 на 1.25×', { size: 12, color: C.muted })]),
      Slider(0.176, 240, { thumb: 12, height: 3 }),
      T('1:03:24 из 6:00:00', { size: 12, color: C.muted }),
    ]),
    H('Chips', { gap: 8, crossAlign: 'center' }, [Chip('1.25×', 'white', { height: 36, size: 13 }), Chip('Сон в 23:00', 'white', { height: 36, size: 13 }), IconButton('bookmark_add_outlined', { color: C.muted })]),
    !phone && H('Tools', { gap: 8, sizingH: 'fill', mainAlign: 'center' }, [IconButton('bookmarks_outlined', { color: C.muted }), IconButton('history', { color: C.muted })]),
  ]);
  const seekW = phone ? 390 : 588;
  return V('Player', { sizingH: 'fill', gap: phone ? 14 : 24, crossAlign: phone ? 'center' : 'min' }, [
    phone
      ? V('Top', { sizingH: 'fill', gap: 20, crossAlign: 'center' }, [Cover(5, coverW, coverH, { radius: 20 })])
      : H('Top', { gap: 28 }, [Cover(5, coverW, coverH, { radius: 20 }), info]),
    phone && info,
    V('Seek', { padding: [8, phone ? 0 : 24, 0, phone ? 0 : 24], gap: 10 }, [
      Slider(0.41, seekW),
      H('Times', { width: seekW, sizingH: 'fixed', mainAlign: 'spaceBetween' }, [T('18:24', { size: 13, color: C.muted }), T('-26:36', { size: 13, color: C.muted })]),
    ]),
    H('Controls', { width: seekW + (phone ? 0 : 48), sizingH: 'fixed', mainAlign: 'center', crossAlign: 'center', gap: phone ? 0 : 4 }, [
      Control('skip_previous_rounded', null, 24),
      Control('fast_rewind_rounded', '-1 мин'),
      Control('fast_rewind_rounded', '-10 с'),
      F('Play', { width: 84, height: 84, cornerRadius: 42, fill: C.accent, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I('pause_rounded', 48, C.onAccent)]),
      Control('fast_forward_rounded', '+10 с'),
      Control('fast_forward_rounded', '+1 мин'),
      Control('skip_next_rounded', null, 24),
    ]),
  ]);
}

const playerDesktop = H('Плеер — десктоп', { width: 1200, height: 1000, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
  Rail('audio'),
  V('Content', { sizingH: 'fill', sizingV: 'fill' }, [
    Header('Сейчас играет', ['style_outlined', 'edit_note', 'bar_chart', 'more_vert']),
    H('Body', { sizingH: 'fill', sizingV: 'fill', padding: [0, 28, 24, 28], gap: 24 }, [PlayerBody(false), ChaptersPanel(380)]),
  ]),
]);

const playerPhone = V('Плеер — телефон', { width: 430, height: 932, sizingH: 'fixed', sizingV: 'fixed', fill: C.bg, clip: true }, [
  Header('Сейчас играет', ['style_outlined', 'more_vert'], { phone: true }),
  V('Body', { sizingH: 'fill', sizingV: 'fill', padding: [0, 20, 16, 20], gap: 16, clip: true }, [PlayerBody(true)]),
  BottomBar('audio'),
]);

// Mini player shown above the bottom bar on other sections.
const miniPlayer = H('Мини-плеер', { width: 430, height: 72, sizingH: 'fixed', sizingV: 'fixed', fill: C.surface, padding: [0, 8, 0, 12], gap: 12, crossAlign: 'center', strokeTopWeight: 1, stroke: C.line }, [
  Cover(5, 40, 56, { detail: false, radius: 4 }),
  V('Text', { sizingH: 'fill', gap: 2 }, [Book('Северный ветер', 15), T('Глава 2. Старый маяк · 18:24', { size: 11, color: C.muted })]),
  IconButton('replay_10'),
  F('Play', { width: 44, height: 44, cornerRadius: 22, fill: C.accent, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [I('pause_rounded', 26, C.onAccent)]),
]);

module.exports = [audioDesktop, playerDesktop, playerPhone, miniPlayer];
