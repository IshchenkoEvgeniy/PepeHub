(() => {
  const root = document.querySelector('.library-v2');
  if (!root) return;
  const $ = (selector) => root.querySelector(selector);
  const icon = (name) => `<svg aria-hidden="true"><use href="#li-${name}"/></svg>`;
  const escape = (value) => String(value).replace(/[&<>"']/g, (character) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[character]));
  const categoryNames = { fiction:'Художественная', nonfiction:'Нон-фикшн', science:'Наука' };
  const books = [
    { id:'threebody', title:'Задача трёх тел', author:'Лю Цысинь', coverTitle:['ЗАДАЧА','ТРЁХ ТЕЛ'], artwork:'orbit', category:'fiction', pages:416, chapters:28, format:'EPUB', progress:64, notes:6, description:'Первый роман трилогии «Память о прошлом Земли». Необъяснимые события заставляют учёных пересмотреть привычную картину мира, а история человечества оказывается частью гораздо более масштабного разговора. Книга о науке, выборе и встрече с неизвестным.' },
    { id:'sapiens', title:'Sapiens', author:'Юваль Ной Харари', coverTitle:['SAPIENS'], artwork:'sapiens', category:'nonfiction', pages:512, chapters:20, format:'EPUB', progress:32, notes:4, description:'Широкий взгляд на историю человечества: от появления первых обществ до экономики, науки и идей, которыми мы объясняем мир. Эта книга помогает замечать связи между привычками отдельного человека и большими переменами в обществе.' },
    { id:'thinking', title:'Думай медленно… решай быстро', author:'Даниэль Канеман', coverTitle:['ДУМАЙ','МЕДЛЕННО'], artwork:'kahneman', category:'nonfiction', pages:656, chapters:38, format:'FB2', progress:18, notes:2, description:'Как мы принимаем решения и почему так часто уверены в ошибочных выводах. Даниэль Канеман исследует интуитивное и вдумчивое мышление, объясняет знакомые когнитивные ловушки и предлагает иначе смотреть на собственные суждения.' },
    { id:'creative', title:'Творческий акт', author:'Рик Рубин', coverTitle:['ТВОРЧЕСКИЙ','АКТ'], artwork:'rubin', category:'nonfiction', pages:432, chapters:78, format:'EPUB', progress:0, notes:0, description:'Размышления о внимании, любопытстве и повседневных условиях, в которых возникают идеи. Рик Рубин предлагает замечать больше, оставлять место неопределённости и относиться к творчеству как к способу взаимодействовать с миром.' },
    { id:'notes', title:'Записки из подполья', author:'Фёдор Достоевский', coverTitle:['Записки','из подполья'], artwork:'dostoevsky', category:'fiction', pages:192, chapters:21, format:'FB2', progress:100, notes:5, description:'Исповедь человека, который стремится понять себя и одновременно спорит с миром. Небольшая повесть соединяет острые наблюдения о свободе, самолюбии и одиночестве с противоречивым голосом рассказчика.' },
    { id:'dune', title:'Дюна', author:'Фрэнк Герберт', coverTitle:['ДЮНА'], artwork:'dune', category:'fiction', pages:704, chapters:48, format:'EPUB', progress:0, notes:0, description:'Пустынная планета Арракис становится центром борьбы за власть и редкий ресурс. Семейная история переплетается с политикой, экологией и вопросами о будущем общества. Начало большого фантастического мира.' },
    { id:'portrait', title:'Портрет художника в юности', author:'Джеймс Джойс', coverTitle:['ПОРТРЕТ','ХУДОЖНИКА'], artwork:'atomic', category:'fiction', pages:352, chapters:5, format:'EPUB', progress:0, notes:0, description:'Роман о взрослении, поиске собственного голоса и постепенном освобождении от чужих ожиданий. Внутренний мир героя меняется вместе с языком повествования: от детских впечатлений к самостоятельному взгляду на искусство и жизнь.' },
    { id:'time', title:'Краткая история времени', author:'Стивен Хокинг', coverTitle:['ИСТОРИЯ','ВРЕМЕНИ'], artwork:'hawking', category:'science', pages:256, chapters:11, format:'PDF', progress:100, notes:3, description:'Введение в вопросы о происхождении Вселенной, пространстве и времени. Стивен Хокинг рассказывает о чёрных дырах, космологических моделях и границах нашего понимания, связывая абстрактные идеи с понятными образами.' },
  ];

  const state = { view:'all', category:'all', query:'', sort:'recent', layout:'grid', selected:'threebody', favorites:new Set(['threebody','dune','portrait']), readerId:null, fontSize:17, bookmark:false };
  const mobileDetails = window.matchMedia('(max-width:1140px)');
  let messageTimer;
  let detailTrigger;
  const currentBook = () => books.find((book) => book.id === state.selected) || books[0];
  const bookPage = (book) => Math.max(1, Math.round(book.pages * book.progress / 100));
  const bookChapter = (book) => Math.min(book.chapters, Math.max(1, Math.round(book.chapters * book.progress / 100)));
  const bookLabel = (book) => book.progress >= 100 ? 'Прочитано' : book.progress > 0 ? `Читаю · ${Math.round(book.progress)}%` : 'На потом';
  const cover = (book) => `<span class="shelf-cover artwork-${book.artwork}"><span class="shelf-cover-kicker">${escape(categoryNames[book.category].toLocaleUpperCase('ru'))}</span><span class="cover-art" aria-hidden="true"></span><span class="shelf-cover-title">${book.coverTitle.map(escape).join('<br>')}</span><span class="shelf-cover-author">${escape(book.author.toLocaleUpperCase('ru'))}</span></span>`;

  function announce(message) {
    window.clearTimeout(messageTimer);
    $('.library-status-message').textContent = message;
    $('.library-status-message').classList.add('is-visible');
    messageTimer = window.setTimeout(() => $('.library-status-message').classList.remove('is-visible'), 2300);
  }

  function renderShelf() {
    const filtered = books.filter((book) => {
      const matchesView = state.view === 'all' || state.view === 'reading' && book.progress > 0 && book.progress < 100 || state.view === 'finished' && book.progress >= 100 || state.view === 'favorites' && state.favorites.has(book.id);
      return matchesView && (state.category === 'all' || state.category === book.category) && `${book.title} ${book.author}`.toLocaleLowerCase('ru').includes(state.query);
    });
    if (state.sort === 'title') filtered.sort((a, b) => a.title.localeCompare(b.title, 'ru'));
    if (state.sort === 'progress') filtered.sort((a, b) => b.progress - a.progress);
    $('#library-books').innerHTML = filtered.map((book) => `<article class="shelf-book ${book.id === state.selected ? 'is-selected' : ''}"><button class="shelf-cover-open" data-select-book="${book.id}" aria-label="Открыть сведения: ${escape(book.title)}">${cover(book)}</button><button class="shelf-favorite ${state.favorites.has(book.id) ? 'is-favorite' : ''}" data-favorite-book="${book.id}" aria-label="${state.favorites.has(book.id) ? 'Убрать из избранного' : 'Добавить в избранное'}: ${escape(book.title)}" aria-pressed="${state.favorites.has(book.id)}">${icon('heart')}</button><div class="shelf-book-copy"><button class="shelf-book-title" data-select-book="${book.id}">${escape(book.title)}</button><p class="shelf-book-author">${escape(book.author)}</p><div class="shelf-book-meta"><span>${book.format}</span><span class="${book.progress >= 100 ? 'book-finished' : book.progress > 0 ? 'book-reading' : ''}">${bookLabel(book)}</span></div>${book.progress > 0 && book.progress < 100 ? `<div class="shelf-inline-progress"><i style="width:${book.progress}%"></i></div>` : ''}</div></article>`).join('');
    $('#library-books').classList.toggle('is-list', state.layout === 'list');
    $('#library-empty').hidden = filtered.length > 0;
    const count = filtered.length;
    const ending = count % 10 === 1 && count % 100 !== 11 ? 'книга' : [2,3,4].includes(count % 10) && ![12,13,14].includes(count % 100) ? 'книги' : 'книг';
    const headings = { all:'На твоей полке', reading:'Сейчас читаешь', favorites:'Избранное', finished:'Прочитано' };
    $('#shelf-title').innerHTML = `${headings[state.view]} <span id="library-result-count">${count} ${ending}</span>`;
    root.querySelectorAll('.reading-nav [data-library-view]').forEach((button) => {
      const active = button.dataset.libraryView === state.view;
      button.classList.toggle('is-current', active);
      if (active) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
    });
    root.querySelectorAll('.genre-tabs [data-library-category]').forEach((button) => {
      const active = button.dataset.libraryCategory === state.category;
      button.classList.toggle('is-current', active);
      button.setAttribute('aria-pressed', String(active));
    });
    const counts = { all:books.length, reading:books.filter((b) => b.progress > 0 && b.progress < 100).length, finished:books.filter((b) => b.progress >= 100).length, favorites:state.favorites.size };
    root.querySelectorAll('[data-view-count]').forEach((node) => node.textContent = counts[node.dataset.viewCount]);
    $('.genre-tabs button[data-library-category="all"] span').textContent = books.length;
    root.querySelectorAll('.reading-collections [data-library-category]').forEach((button) => button.querySelector('small').textContent = books.filter((book) => book.category === button.dataset.libraryCategory).length);
    $('.search-clear').hidden = state.query.length === 0;
    $('.library-search kbd').hidden = state.query.length > 0;
  }

  function renderContinue() {
    const book = books.find((b) => b.id === state.readerId && b.progress > 0 && b.progress < 100) || books.find((b) => b.progress > 0 && b.progress < 100);
    $('.continue-section').hidden = !book;
    if (!book) return;
    $('#library-continue').innerHTML = `<button class="continue-cover-button" data-select-book="${book.id}" aria-label="Сведения о книге ${escape(book.title)}">${cover(book)}</button><div class="continue-book-info"><span>ВЕРНУТЬСЯ В ИСТОРИЮ</span><h3>${escape(book.title)}</h3><p>${escape(book.author)}</p><button class="primary-library-button" data-read-book="${book.id}">Продолжить ${icon('arrow')}</button></div><div class="continue-progress"><div class="progress-ring" style="--progress:${book.progress}" aria-label="Прочитано ${Math.round(book.progress)} процентов"><b>${Math.round(book.progress)}<small>%</small></b></div><span>ГЛАВА ${bookChapter(book)} ИЗ ${book.chapters}</span><small>Страница ${bookPage(book)} из ${book.pages}</small></div>`;
  }

  function renderDetails() {
    const book = currentBook();
    const favorite = state.favorites.has(book.id);
    $('#library-details').innerHTML = `<div class="detail-scroll"><div class="detail-topline"><span>О КНИГЕ</span><button class="detail-close library-icon-button" aria-label="Закрыть сведения о книге">${icon('close')}</button></div><div class="detail-cover-wrap">${cover(book)}</div><h2 class="detail-title">${escape(book.title)}</h2><p class="detail-author">${escape(book.author)}</p><span class="detail-category">${escape(categoryNames[book.category].toLocaleUpperCase('ru'))}</span><div class="detail-metadata"><div><small>Страниц</small><strong>${book.pages}</strong></div><div><small>Формат</small><strong>${book.format}</strong></div><div><small>Язык</small><strong>Русский</strong></div></div><h3 class="detail-section-title">О чём эта книга</h3><p class="detail-description">${escape(book.description)}</p><button class="detail-expand" aria-expanded="false">Читать дальше</button><div class="detail-notes">${icon('note')}<div><b>Твои заметки</b><small>${book.notes ? 'Мысли, к которым можно вернуться' : 'Здесь появятся сохранённые мысли'}</small></div><span>${String(book.notes).padStart(2,'0')}</span></div></div><div class="detail-actions"><button class="primary-library-button detail-read-button" data-read-book="${book.id}">${icon('book')}${book.progress >= 100 ? 'Открыть заново' : book.progress > 0 ? 'Продолжить чтение' : 'Начать читать'}</button><button class="detail-favorite" data-favorite-book="${book.id}" aria-pressed="${favorite}">${icon('heart')}${favorite ? 'В избранном' : 'Добавить в избранное'}</button><p class="detail-read-location">${book.progress > 0 ? `Страница ${bookPage(book)} из ${book.pages} · ${Math.round(book.progress)}%` : 'Всё начинается с первой страницы'}</p></div>`;
  }

  function closeDetails() {
    root.classList.remove('detail-is-open');
    $('.library-detail-backdrop').hidden = true;
    $('#library-details').removeAttribute('aria-modal');
    $('#library-details').removeAttribute('role');
    if (detailTrigger?.isConnected && mobileDetails.matches) detailTrigger.focus({preventScroll:true});
  }

  function selectBook(id, trigger) {
    state.selected = id;
    renderShelf();
    renderDetails();
    detailTrigger = $(`[data-select-book="${id}"]`) || trigger;
    if (mobileDetails.matches) {
      root.classList.add('detail-is-open');
      $('.library-detail-backdrop').hidden = false;
      $('#library-details').setAttribute('role', 'dialog');
      $('#library-details').setAttribute('aria-modal', 'true');
      $('.detail-close').focus();
    }
  }

  const readerText = [
    ['К вечеру дом стал тише. За окном ещё двигался город, но здесь остались только лампа, раскрытая книга и чашка, которую давно пора было отнести на кухню.', 'Он вернулся на несколько строк назад. Иногда мысль становилась понятной лишь со второго прочтения — когда перестаёшь торопиться к следующей странице и даёшь ей немного места.', 'На полях появилась короткая запись. Не вывод, скорее вопрос, с которым хотелось вернуться к этой истории позже. Дальше текст уже воспринимался иначе: словно разговор наконец обрёл собственный ритм.', 'До конца главы оставалось совсем немного. Он поправил закладку и продолжил читать.'],
    ['Утром запись на полях оказалась неожиданно полезной. Слова, которые вечером казались неясными, теперь складывались в простую последовательность.', 'Он открыл книгу у окна и прочёл следующий абзац. В повседневных делах всегда находилось достаточно причин отложить чтение; сегодняшнее утро стало небольшим исключением.', 'Каждая новая страница добавляла к истории подробность. Постепенно возникало ощущение знакомого места, в которое можно возвращаться без спешки.', 'Закладка переместилась дальше. За окном начинался день.'],
    ['Дорога заняла больше времени, чем обычно. Он достал книгу и нашёл место, на котором остановился утром.', 'Сначала мешал шум, потом он отступил на задний план. Небольшой фрагмент оказался достаточно цельным, чтобы удержать внимание и оставить после себя вопрос.', 'Мысли о прочитанном продолжались и после того, как книга была закрыта. Иногда важная часть истории начинается именно в этот момент.', 'Вечером хотелось вернуться и сравнить первое впечатление с тем, что стало понятнее за день.'],
  ];

  function updateReader() {
    const book = books.find((b) => b.id === state.readerId);
    $('#reader-book-title').textContent = book.title;
    const page = bookPage(book);
    $('.library-reading-page').innerHTML = `<span class="reading-eyebrow">ГЛАВА ${bookChapter(book)}</span><h2>Время для одной главы</h2>${readerText[page % readerText.length].map((paragraph) => `<p>${paragraph}</p>`).join('')}`;
    $('.library-reading-page').style.fontSize = `${state.fontSize}px`;
    $('#reader-page-label').textContent = `Страница ${page} из ${book.pages}`;
    $('#reader-next-page').disabled = page >= book.pages;
    $('#reader-bookmark').setAttribute('aria-pressed', String(state.bookmark));
  }

  root.addEventListener('click', (event) => {
    const select = event.target.closest('[data-select-book]');
    if (select) selectBook(select.dataset.selectBook, select);
    const view = event.target.closest('[data-library-view]');
    if (view) { state.view = view.dataset.libraryView; renderShelf(); }
    const category = event.target.closest('[data-library-category]');
    if (category) { state.category = category.dataset.libraryCategory; renderShelf(); }
    const favorite = event.target.closest('[data-favorite-book]');
    if (favorite) {
      const id = favorite.dataset.favoriteBook;
      const fromDetails = favorite.classList.contains('detail-favorite');
      if (state.favorites.has(id)) { state.favorites.delete(id); announce('Книга убрана из избранного'); } else { state.favorites.add(id); announce('Книга добавлена в избранное'); }
      renderShelf(); renderDetails();
      if (fromDetails) $('.detail-favorite').focus({preventScroll:true});
      else $(`[data-favorite-book="${id}"]`)?.focus({preventScroll:true});
    }
    const layout = event.target.closest('[data-shelf-layout]');
    if (layout) {
      state.layout = layout.dataset.shelfLayout;
      root.querySelectorAll('[data-shelf-layout]').forEach((button) => { const selected = button === layout; button.classList.toggle('is-current', selected); button.setAttribute('aria-pressed', String(selected)); });
      renderShelf();
    }
    const read = event.target.closest('[data-read-book]');
    if (read) {
      state.readerId = read.dataset.readBook;
      state.bookmark = false;
      const book = books.find((b) => b.id === state.readerId);
      if (book.progress >= 100) book.progress = 0;
      closeDetails(); updateReader(); renderShelf(); renderDetails(); renderContinue();
      $('#library-reader').showModal();
    }
    const close = event.target.closest('[data-close-dialog]');
    if (close) document.getElementById(close.dataset.closeDialog).close();
    if (event.target.closest('.detail-close,.library-detail-backdrop')) closeDetails();
    if (event.target.closest('.detail-expand')) { const expanded = $('.detail-description').classList.toggle('is-expanded'); $('.detail-expand').setAttribute('aria-expanded', String(expanded)); $('.detail-expand').textContent = expanded ? 'Свернуть' : 'Читать дальше'; }
  });

  $('#library-search').addEventListener('input', (event) => { state.query = event.target.value.trim().toLocaleLowerCase('ru'); renderShelf(); });
  $('.search-clear').addEventListener('click', () => { $('#library-search').value = ''; state.query = ''; renderShelf(); $('#library-search').focus(); });
  $('#library-sort').addEventListener('change', (event) => { state.sort = event.target.value; renderShelf(); });
  $('#library-reset').addEventListener('click', () => { state.view = 'all'; state.category = 'all'; state.query = ''; $('#library-search').value = ''; renderShelf(); });
  $('.library-add').addEventListener('click', () => $('#library-import').showModal());
  $('#library-import-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const form = new FormData(event.target);
    const title = String(form.get('title')).trim();
    const author = String(form.get('author')).trim();
    if (!title || !author) return;
    const book = { id:`new-${Date.now()}`, title, author, coverTitle:title.split(/\s+/).reduce((lines, word) => { if (!lines.length || lines[lines.length - 1].length + word.length > 14) lines.push(word.toLocaleUpperCase('ru')); else lines[lines.length - 1] += ` ${word.toLocaleUpperCase('ru')}`; return lines; }, []).slice(0,4), artwork:'atomic', category:String(form.get('category')), pages:300, chapters:20, format:String(form.get('format')), progress:0, notes:0, description:'Новая книга в личной библиотеке. Открой её, чтобы познакомиться с историей, и сохрани свои первые мысли.' };
    books.unshift(book);
    state.selected = book.id; state.view = 'all'; state.category = 'all'; state.query = ''; state.sort = 'recent';
    $('#library-search').value = ''; $('#library-sort').value = 'recent';
    renderShelf(); renderDetails(); $('#library-import').close(); event.target.reset(); announce('Книга добавлена на твою полку');
  });
  $('#reader-next-page').addEventListener('click', () => {
    const book = books.find((b) => b.id === state.readerId);
    book.progress = Math.min(100, (bookPage(book) + 1) / book.pages * 100);
    updateReader(); renderContinue(); renderShelf(); renderDetails();
  });
  $('#reader-font-down').addEventListener('click', () => { state.fontSize = Math.max(14, state.fontSize - 1); updateReader(); });
  $('#reader-font-up').addEventListener('click', () => { state.fontSize = Math.min(24, state.fontSize + 1); updateReader(); });
  $('#reader-bookmark').addEventListener('click', () => { state.bookmark = !state.bookmark; $('#reader-bookmark').setAttribute('aria-pressed', String(state.bookmark)); });
  root.querySelectorAll('dialog').forEach((dialog) => dialog.addEventListener('click', (event) => { if (event.target === dialog) { const rectangle = dialog.getBoundingClientRect(); if (event.clientX < rectangle.left || event.clientX > rectangle.right || event.clientY < rectangle.top || event.clientY > rectangle.bottom) dialog.close(); } }));
  document.querySelectorAll('.concept-tab').forEach((tab) => tab.addEventListener('click', () => { if (tab.dataset.concept !== 'library') { closeDetails(); root.querySelectorAll('dialog[open]').forEach((dialog) => dialog.close()); } }));
  mobileDetails.addEventListener('change', closeDetails);
  document.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !root.querySelector('dialog[open]')) { event.preventDefault(); document.querySelector('[data-concept="library"]').click(); $('#library-search').focus(); }
    if (root.classList.contains('detail-is-open') && mobileDetails.matches) {
      if (event.key === 'Escape') { closeDetails(); event.preventDefault(); }
      if (event.key === 'Tab') { const controls = [...$('#library-details').querySelectorAll('button')]; const first = controls[0]; const last = controls[controls.length - 1]; if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); } else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); } }
    }
  });
  renderShelf(); renderContinue(); renderDetails();
})();
