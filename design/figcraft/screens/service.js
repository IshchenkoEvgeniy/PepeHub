// Service windows and dialogs: hidden/unavailable, add series, reading plan,
// Anki vocabulary, error log, statistics exchange, updates, dialogs, menus.
'use strict';
const { C, FONT, F, H, V, T, I, R, E, Book, Display, Spacer } = require('../lib');
const { DesktopScreen, SubScreen, Search, Chip, Button, Card, IconButton, Cover, ProgressBar, COVERS } = require('../components');

const textTabs = (items, sel = 0) => H('Tabs', { sizingH: 'fill', gap: 24, strokeBottomWeight: 1, stroke: C.line, padding: [0, 12, 0, 12] }, items.map((t, i) => V(`Tab/${t}`, { gap: 10 }, [T(t, { size: 15, w: i === sel ? 700 : 500, color: i === sel ? C.text : C.muted }), R('Underline', { width: 40, height: 3, cornerRadius: 2, fill: i === sel ? C.accent : '#00000000', sizingH: 'fill' })])));

const hidden = SubScreen('Скрытые и недоступные', 'Скрытые и недоступные', [], [
  textTabs(['Скрытые 2', 'Файл не найден 1', 'Без файла 0', 'Корзина 3']),
  V('Body', { sizingH: 'fill', padding: [0, 12, 0, 12], gap: 16 }, [
    T('Книги, скрытые с полки. Файлы, прогресс и заметки на месте — верните книгу, когда понадобится.', { size: 13, color: C.muted }),
    Search('Поиск по названию'),
    H('Filters', { gap: 8 }, [Chip('Все', 'accent', { icon: 'check', height: 34, size: 13 }), Chip('Книги', 'outline', { height: 34, size: 13 }), Chip('Аудиокниги', 'outline', { height: 34, size: 13 })]),
    ...[3, 4].map((c) => H(`Hidden/${COVERS[c][1]}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 16, padding: 12, gap: 14, crossAlign: 'center' }, [Cover(c, 40, 58, { detail: false, radius: 3 }), V('T', { sizingH: 'fill', gap: 2 }, [Book(COVERS[c][1], 16), T(`${COVERS[c][2]} · скрыта 2 ноября`, { size: 12, color: C.muted })]), Button('Вернуть на полку', { icon: 'visibility_off_outlined', kind: 'outline', height: 38 }), IconButton('more_vert', { color: C.muted })])),
  ]),
], { bodyPadding: [0, 12, 12, 12] });

const field = (label, value, { trailing = null, height = 52, top = false } = {}) => V(`Field/${label}`, { sizingH: 'fill', gap: 0 }, [
  H('Box', { sizingH: 'fill', height, sizingV: 'fixed', fill: C.surface, cornerRadius: 14, stroke: C.line, strokeWeight: 1, padding: [top ? 14 : 0, 20, 0, 22], crossAlign: top ? 'min' : 'center' }, [
    value ? V('V', { sizingH: 'fill', gap: 2 }, [T(label, { size: 10, color: C.muted }), T(value, { size: 16 })]) : T(label, { size: 14, color: C.muted, sizingH: 'fill' }),
    trailing && I(trailing, 24, C.muted),
  ]),
]);

const series = SubScreen('Добавить серию', 'Добавить серию', [], [
  V('Body', { sizingH: 'fill', sizingV: 'fill', padding: [12, 56, 0, 56], gap: 20 }, [
    T('Добавьте тома серии, включая ещё не прочитанные или не прослушанные.', { size: 13 }),
    H('Columns', { sizingH: 'fill', gap: 24 }, [
      V('Common', { width: 340, sizingH: 'fixed', gap: 16 }, [T('Общее для серии', { size: 16, w: 500 }), field('Название серии', 'Морские истории'), field('Авторы', null, { trailing: 'add' }), field('Тип произведений', 'Книги', { trailing: 'arrow_drop_down' }), field('Жанры', null, { trailing: 'add' }), field('Статус томов', 'Завершённая', { trailing: 'arrow_drop_down' }), H('Edition', { sizingH: 'fill', padding: [8, 0, 0, 0] }, [T('Издание и теги', { size: 16, sizingH: 'fill' }), I('expand_more', 22, C.muted)])]),
      V('Volumes', { sizingH: 'fill', gap: 16 }, [T('Тома по порядку', { size: 16, w: 500 }), field('Номер первого тома', '1'), V('Titles', { sizingH: 'fill', height: 148, sizingV: 'fixed', fill: C.surface, cornerRadius: 14, stroke: C.line, strokeWeight: 1, padding: [16, 22, 16, 22], gap: 6 }, ['1. Атлас тишины', '2. Северный ветер', '2.5. Письмо с маяка', '3. Город у моря'].map((t) => T(t, { size: 15 }))), T('Можно с номерами: 1. Название, 0.5. Предыстория', { size: 12, color: C.muted }), T('Даты, оценки и объём можно указать отдельно для каждого тома на следующем шаге.', { size: 13 })]),
    ]),
    Spacer('v'),
    H('Footer', { sizingH: 'fill', mainAlign: 'max' }, [F('Next', { width: 320, height: 48, cornerRadius: 24, fill: C.accent, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [T('Проверить тома', { size: 15, w: 700 })])]),
  ]),
], { bodyPadding: [0, 0, 24, 0] });

const plan = DesktopScreen('План чтения', 'books', 'План чтения', ['notifications_outlined', 'refresh'], [
  T('Северный ветер', { size: 13, color: C.muted }),
  F('Gap', { width: 1, height: 20 }),
  H('Cards', { sizingH: 'fill', gap: 16 }, [
    Card('Settings', { width: 465, sizingH: 'fixed', cornerRadius: 22, gap: 16 }, [
      T('Настройки плана', { font: FONT.serif, w: 700, size: 26 }), T('Создайте личный план для этой книги.', { size: 14, color: C.muted }),
      H('Minutes', { sizingH: 'fill', height: 52, sizingV: 'fixed', cornerRadius: 14, stroke: C.strong, strokeWeight: 1, padding: [0, 16, 0, 16], crossAlign: 'center' }, [I('remove', 22, C.muted), Spacer('h'), V('V', { crossAlign: 'center' }, [T('Минут в день', { size: 9, color: C.muted }), T('20', { size: 16 })]), Spacer('h'), I('add', 22, C.muted)]),
      H('Hint', { sizingH: 'fill', padding: [0, 20, 0, 20] }, [T('Активное чтение этой книги · 1–1440', { size: 12, color: C.muted, sizingH: 'fill' }), T('2/4', { size: 12, color: C.muted })]),
      H('Volume', { sizingH: 'fill' }, [T('Цель по объёму', { size: 14, sizingH: 'fill' }), T('первые 100%', { size: 14, w: 700 })]),
      F('Slider', { width: 380, height: 20 }, [R('Track', { width: 380, height: 4, y: 8, x: 0, cornerRadius: 2, fill: C.accent }), E('Thumb', { width: 20, height: 20, x: 360, y: 0, fill: C.accent })]),
      H('Deadline', { sizingH: 'fill', fill: C.raised, cornerRadius: 14, padding: [16, 18, 16, 18], gap: 16, crossAlign: 'center' }, [I('event_outlined', 24, C.muted), V('T', { sizingH: 'fill' }, [T('Срок завершения', { size: 16 }), T('Без срока', { size: 14 })]), I('edit_calendar_outlined', 24, C.muted)]),
      Button('Сохранить план', { icon: 'check' }),
    ]),
    Card('Forecast', { cornerRadius: 22, gap: 16 }, [
      T('Прогноз', { font: FONT.serif, w: 700, size: 26 }),
      H('Ring', { gap: 20, crossAlign: 'center' }, [F('Ring', { width: 120, height: 120 }, [E('Track', { width: 120, height: 120, x: 0, y: 0, fills: [], stroke: C.raised, strokeWeight: 10 }), V('V', { x: 0, y: 36, width: 120, sizingH: 'fixed', crossAlign: 'center' }, [Display('0', 30), T('из 20 мин', { size: 11, color: C.muted })])]), V('T', { gap: 4 }, [T('Сегодня', { size: 12, color: C.muted }), Display('Мало данных', 26)])]),
      H('Counted', { sizingH: 'fill' }, [T('Учтено 0.0% книги', { size: 14, sizingH: 'fill' }), T('цель 100%', { size: 13, color: C.muted })]),
      ProgressBar(0, { width: 520, height: 10 }),
      T('Пока мало данных для прогноза. Нужно не менее минуты измеренного чтения, 300 знаков и двух обычных переходов.', { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }),
    ]),
  ]),
  F('Gap', { width: 1, height: 16 }),
  T('Прогноз приблизительный: он основан на активном чтении этой версии книги. Паузы, бездействие и переходы по поиску, оглавлению или ползунку исключаются из замера скорости.', { size: 12, color: C.muted, sizingH: 'fill', textAutoResize: 'height' }),
], { bodyPadding: [0, 28, 20, 28] });

const vocabulary = SubScreen('Словарь — карточки Anki', 'Карточки Anki', ['select_all', 'upload_file'], [
  Search('Поиск слов, фраз и источников'),
  H('Filters', { gap: 8 }, [Chip('Все', 'accent', { icon: 'check', height: 34, size: 13 }), Chip('Слова', 'outline', { height: 34, size: 13 }), Chip('Предложения', 'outline', { height: 34, size: 13 })]),
  ...[['serendipity', 'счастливая случайность', 'Атлас тишины · Глава 3'], ['to linger', 'задерживаться, медлить', 'Северный ветер · Глава 1'], ['The wind carried the smell of the sea.', 'Ветер принёс запах моря.', 'Северный ветер · Глава 1']].map(([front, back, src]) => H(`Card/${front}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 16, padding: [14, 12, 14, 18], gap: 12, crossAlign: 'center' }, [V('T', { sizingH: 'fill', gap: 4 }, [T(front, { size: 17, w: 700 }), T(back, { size: 14 }), T(src, { size: 12, color: C.muted })]), I('check_box_outline_blank', 22, C.muted), IconButton('more_vert', { color: C.muted })])),
  F('FabRow', { sizingH: 'fill', width: 10, height: 56, layout: 'horizontal', mainAlign: 'max' }, [Button('Новая карточка Anki', { icon: 'add', height: 56 })]),
]);

const errors = SubScreen('Журнал ошибок', 'Журнал ошибок', ['refresh', 'copy_outlined', 'delete_outline'], [
  ...[['16.11.2026 14:02', 'FileSystemException: Не удаётся открыть файл', 'D:\\Книги\\Город у моря.epub'], ['15.11.2026 21:47', 'Аудио: таймаут чтения длительности', 'Северный ветер / 03.mp3']].map(([d, e, s]) => V(`Error/${d}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 14, padding: 16, gap: 4 }, [H('Head', { gap: 8, crossAlign: 'center' }, [I('error_outline', 18, '#f06464'), T(d, { size: 12, color: C.muted })]), T(e, { size: 14, w: 500 }), T(s, { size: 12, color: C.muted })])),
]);

const exchange = SubScreen('Обмен статистикой', 'Обмен статистикой', [], [
  V('Column', { sizingH: 'fill', padding: [12, 200, 0, 200], gap: 16 }, [
    T('Перенос сессий чтения и прослушивания между устройствами без общей папки библиотеки.', { size: 13, color: C.muted, sizingH: 'fill', textAutoResize: 'height' }),
    Card('Export', { cornerRadius: 20 }, [T('Экспорт', { font: FONT.serif, w: 700, size: 24 }), T('Все сессии, цели и планы в одном JSON-файле.', { size: 13, color: C.muted }), Button('Экспортировать всё · JSON', { icon: 'file_download_outlined' })]),
    Card('Import', { cornerRadius: 20 }, [T('Импорт', { font: FONT.serif, w: 700, size: 24 }), T('Новые записи добавятся, совпадающие будут пропущены.', { size: 13, color: C.muted }), Button('Выбрать файл для импорта', { icon: 'upload_file', kind: 'outline' }), V('Preview', { sizingH: 'fill', fill: C.raised, cornerRadius: 12, padding: 14, gap: 4 }, [T('pepehub-statistics-2026-11-16.json', { size: 13, w: 700 }), T('Новых сессий: 18 · уже есть: 112 · книг: 6', { size: 12, color: C.muted })]), Button('Импортировать новые записи', { icon: 'check' })]),
  ]),
]);

const update = SubScreen('Обновление приложения', 'Обновление приложения', [], [
  V('Column', { sizingH: 'fill', padding: [12, 200, 0, 200], gap: 16 }, [
    Card('Version', { cornerRadius: 20 }, [H('Head', { sizingH: 'fill', crossAlign: 'center', gap: 12 }, [I('system_update_alt', 28, C.accent), V('T', { sizingH: 'fill' }, [T('Доступна версия 0.32.0', { size: 18, w: 700 }), T('Установлена 0.31.11 · 18 МБ, дельта-обновление 2,4 МБ', { size: 13, color: C.muted })])]), ProgressBar(0.64, { width: 720, height: 6 }), T('Загрузка… 64%', { size: 12, color: C.muted }), H('Actions', { gap: 8 }, [Button('Установить', { icon: 'download' }), Button('Подробнее', { kind: 'outline' })])]),
    Card('Notes', { cornerRadius: 20 }, [T('Что нового', { font: FONT.serif, w: 700, size: 24 }), ...['Серии с непрочитанными томами в библиотеке', 'Быстрее открывается список из тысяч книг', 'Исправлен возврат после таймера сна'].map((t) => H('Item', { gap: 10, crossAlign: 'center' }, [I('check', 18, C.accent), T(t, { size: 14 })]))]),
  ]),
]);

// Dialogs and menus on a dimmed backdrop.
function Backdrop(name, child, { width = 900, height = 640 } = {}) {
  return F(name, { width, height, fill: '#0b0b0bee', layout: 'horizontal', mainAlign: 'center', crossAlign: 'center', clip: true }, [child]);
}
const deleteDialog = Backdrop('Диалог — удалить книгу', V('Dialog', { width: 460, sizingH: 'fixed', fill: C.raised, cornerRadius: 28, padding: 24, gap: 16 }, [
  T('Удалить «Город у моря»?', { size: 22, w: 500 }),
  T('Карточка, прогресс и заметки переместятся в корзину. Файл книги можно удалить с диска или оставить на месте.', { size: 14, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }),
  H('Option', { sizingH: 'fill', gap: 12, crossAlign: 'center' }, [I('check_box_outline_blank', 22, C.muted), T('Удалить и файл с диска', { size: 14 })]),
  H('Actions', { sizingH: 'fill', mainAlign: 'max', gap: 8 }, [Button('Отмена', { kind: 'text' }), Button('Удалить', { icon: 'delete_outline' })]),
]));

const menuItem = (icon, label, danger) => H(`Item/${label}`, { sizingH: 'fill', height: 44, sizingV: 'fixed', padding: [0, 16, 0, 14], gap: 14, crossAlign: 'center' }, [icon && I(icon, 20, danger ? '#f06464' : C.muted), T(label, { size: 14, color: danger ? '#f06464' : C.text })]);
const menu = Backdrop('Меню — действия с книгой', V('Menu', { width: 280, sizingH: 'fixed', fill: C.raised, cornerRadius: 12, padding: [8, 0, 8, 0], effects: [{ type: 'dropShadow', color: '#00000080', offset: [0, 8], radius: 24 }] }, [
  menuItem('play_arrow', 'Продолжить чтение'), menuItem('edit_outlined', 'Изменить данные'), menuItem('favorite_border', 'В избранное'), menuItem('event_outlined', 'План чтения'), menuItem('bar_chart_outlined', 'Статистика книги'), menuItem('local_library_outlined', 'Добавить в библиотеку'), menuItem('drive_file_move_outlined', 'Переместить файл…'), menuItem('visibility_off_outlined', 'Скрыть с полки'), R('Divider', { width: 280, height: 1, fill: C.line }), menuItem('delete_outline', 'Удалить…', true),
]), { width: 600, height: 560 });

const snackbar = F('Уведомление — снекбар', { width: 600, height: 120, fill: C.bg, layout: 'horizontal', mainAlign: 'center', crossAlign: 'center' }, [
  H('SnackBar', { width: 520, sizingH: 'fixed', fill: '#e8e8e8', cornerRadius: 6, padding: [14, 8, 14, 16], crossAlign: 'center' }, [T('Найдено 3 новые книги в папке «Книги»', { size: 14, color: '#1e1e1e', sizingH: 'fill' }), T('ПАПКИ', { size: 13, w: 700, color: C.accent })]),
]);

module.exports = [hidden, series, plan, vocabulary, errors, exchange, update, deleteDialog, menu, snackbar];
