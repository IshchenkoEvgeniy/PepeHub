// «Рекомендации»: categories, saved books and the online search.
'use strict';
const { C, FONT, F, H, V, T, I, R, Book, Display, Spacer } = require('../lib');
const { DesktopScreen, PhoneScreen, Search, Button, CoverIcon, Cover, Chip, SubScreen, COVERS } = require('../components');

const CATS = [['Все книги', 4], ['Хочу прочитать', 0], ['Топ магической фантастики', 0], ['Советовали друзья', 0], ['Следующие книги', 4], ['Любимые истории', 2], ['Без категории', 0]];
const BOOKS = [
  [0, 'Следующие книги · #3', null, 'Обсудить в книжном клубе'],
  [1, 'Следующие книги · #2', 'Любимые истории · #2', 'Продолжение морских историй'],
  [2, 'Следующие книги · #4', null, 'Совет друга'],
  [5, 'Следующие книги · #1', 'Любимые истории · #1', 'Для тихого вечера'],
];

function Categories() {
  return V('Categories', { width: 232, sizingH: 'fixed', gap: 2, padding: [6, 0, 0, 0] }, [
    Display('Категории'.toUpperCase(), 18, C.text, { name: 'Title' }),
    F('Gap', { width: 1, height: 8 }),
    ...CATS.map(([name, n], i) => H(`Category/${name}`, { sizingH: 'fill', height: 38, sizingV: 'fixed', padding: [0, 12, 0, 12], crossAlign: 'center', cornerRadius: 10, ...(i === 0 && { fill: C.selected }) }, [T(name, { size: 13, w: i === 0 ? 700 : 500, sizingH: 'fill' }), T(String(n), { size: 12, color: C.muted })])),
    F('Gap', { width: 1, height: 18 }),
    H('NewCategory', { gap: 8, padding: [0, 12, 0, 12], crossAlign: 'center' }, [I('create_new_folder_outlined', 20, C.accent), T('Новая категория', { size: 14, w: 500, color: C.accent })]),
  ]);
}

function BookCard([cover, cat1, cat2, note]) {
  const [, title, author] = COVERS[cover];
  return H(`Recommendation/${title}`, { sizingH: 'fill', fill: C.surface, cornerRadius: 18, padding: [12, 20, 14, 14], gap: 14 }, [
    CoverIcon(60, 85, 'menu_book'),
    V('Text', { sizingH: 'fill', gap: 6 }, [
      Book(title, 18), T(author, { size: 13, color: C.muted }),
      H('Categories', { gap: 10, sizingH: 'fill', wrap: true, crossGap: 4 }, [T(cat1, { size: 12, w: 500, color: C.accent }), cat2 && T(cat2, { size: 12, w: 500, color: C.accent }), T('Вручную', { size: 12, color: C.muted })]),
      T(note, { size: 13, w: 500 }),
    ]),
    I('more_vert', 22),
  ]);
}

function Main() {
  return V('Books', { sizingH: 'fill', gap: 14 }, [
    V('Head', { gap: 2 }, [Display('Все книги', 32), T('4 книг · по названию', { size: 12, color: C.muted })]),
    Search('Поиск в моих подборках'),
    H('Actions', { gap: 10 }, [Button('Найти книгу в интернете', { icon: 'travel_explore' }), Button('Добавить вручную', { icon: 'add', kind: 'outline' })]),
    V('Sort', { sizingH: 'fill', gap: 0 }, [
      H('Field', { sizingH: 'fill', height: 52, sizingV: 'fixed', fill: C.surface, cornerRadius: 14, stroke: C.line, strokeWeight: 1, padding: [0, 16, 0, 20], crossAlign: 'center' }, [
        V('Value', { sizingH: 'fill', gap: 2 }, [T('Сортировка', { size: 9, color: C.muted }), T('По названию', { size: 15 })]), I('arrow_drop_down', 24, C.muted),
      ]),
    ]),
    ...BOOKS.map(BookCard),
  ]);
}

const hint = V('Detail', { width: 360, sizingH: 'fixed', cornerRadius: 18, stroke: C.line, strokeWeight: 1, padding: [18, 20, 18, 20] }, [
  T('Выберите книгу в списке, чтобы увидеть описание и заметку. Двойное нажатие открывает карточку.', { size: 12, color: C.muted, sizingH: 'fill', textAutoResize: 'height', lineHeight: '150%' }),
]);

const desktop = DesktopScreen('Рекомендации — десктоп', 'recommendations', 'Рекомендации', ['manage_search', 'copy_all_outlined'], [
  H('Columns', { sizingH: 'fill', gap: 24 }, [Categories(), Main(), hint]),
], { bodyPadding: [0, 20, 20, 28] });

const phone = PhoneScreen('Рекомендации — телефон', 'recommendations', 'Рекомендации', ['manage_search'], [
  H('Categories', { gap: 8, sizingH: 'fill', clip: true }, [Chip('Все книги · 4', 'accent', { height: 34, size: 13 }), Chip('Следующие книги · 4', 'outline', { height: 34, size: 13 }), Chip('Любимые истории · 2', 'outline', { height: 34, size: 13 })]),
  F('Gap', { width: 1, height: 14 }),
  Search('Поиск в моих подборках'),
  F('Gap', { width: 1, height: 12 }),
  H('Actions', { gap: 8 }, [Button('Найти в интернете', { icon: 'travel_explore', height: 40 }), Button('Вручную', { icon: 'add', kind: 'outline', height: 40 })]),
  F('Gap', { width: 1, height: 14 }),
  V('List', { sizingH: 'fill', gap: 10 }, BOOKS.map(BookCard)),
]);

// Recommendation detail (RecommendationDetailPage).
const detail = SubScreen('Рекомендация — карточка', 'Рекомендация', ['edit', 'more_vert'], [
  H('Top', { sizingH: 'fill', gap: 28, padding: [8, 80, 0, 80] }, [
    Cover(1, 200, 290, { radius: 6 }),
    V('Text', { sizingH: 'fill', gap: 10 }, [
      Book('Атлас тишины', 34), T('Михаил Лесной', { size: 15, color: C.muted }),
      H('Tags', { gap: 8 }, [Chip('Современная проза', 'outline', { height: 30, size: 12 }), Chip('Путешествия', 'outline', { height: 30, size: 12 })]),
      T('Категории', { size: 12, w: 700, color: C.muted, letterSpacing: 1 }),
      H('Cats', { gap: 8 }, [Chip('Следующие книги · #2', 'accent', { height: 30, size: 12 }), Chip('Любимые истории · #2', 'accent', { height: 30, size: 12 })]),
      T('Заметка', { size: 12, w: 700, color: C.muted, letterSpacing: 1 }),
      T('Продолжение морских историй', { size: 15 }),
      H('Actions', { gap: 10, padding: [8, 0, 0, 0] }, [Button('Добавить в «Книги»', { icon: 'add' }), Button('Открыть источник', { icon: 'open_in_browser', kind: 'outline' })]),
    ]),
  ]),
  V('About', { sizingH: 'fill', gap: 8, padding: [12, 80, 0, 80] }, [
    T('Описание', { size: 18, w: 500 }),
    T('Сборник коротких историй о прибрежных городах, маяках и людях, которые учатся слушать тишину. Каждая глава — отдельная прогулка вдоль моря.', { size: 14, sizingH: 'fill', textAutoResize: 'height', lineHeight: '155%' }),
  ]),
]);

module.exports = [desktop, phone, detail];
