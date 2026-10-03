import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../recommendations/book_catalog.dart';
import '../recommendations/recommendation_store.dart';
import 'shelf_components.dart';

class RecommendationsPage extends StatefulWidget {
  final RecommendationStore store;
  final BookCatalog catalog;
  final Widget? drawer, sidebar;
  const RecommendationsPage({
    super.key,
    required this.store,
    required this.catalog,
    this.drawer,
    this.sidebar,
  });
  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  RecommendationShelf? shelf;
  String? category, error;
  String query = '';
  bool loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await widget.store.load();
      if (!mounted) return;
      setState(() {
        shelf = next;
        loading = false;
        error = null;
        if (category != '' && !next.categories.any((c) => c.id == category)) {
          category = null;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Не удалось прочитать подборки: $e';
          loading = false;
        });
      }
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) _message('$e');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _edit({RecommendedBook? book, CatalogBook? found}) async {
    if (shelf == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RecommendationEditor(
          store: widget.store,
          catalog: widget.catalog,
          categories: shelf!.categories,
          book: book,
          found: found,
          initialCategory: category,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _search() async {
    final book = await Navigator.push<CatalogBook>(
      context,
      MaterialPageRoute(
        builder: (_) => RecommendationSearchPage(
          store: widget.store,
          catalog: widget.catalog,
        ),
      ),
    );
    if (mounted && book != null) {
      final duplicate = shelf!.books
          .where(
            (b) =>
                b.catalog.source == book.source &&
                b.catalog.sourceId == book.sourceId,
          )
          .firstOrNull;
      await _edit(book: duplicate, found: duplicate == null ? book : null);
    }
  }

  Future<void> _category({RecommendationCategory? existing}) async {
    final controller = TextEditingController(text: existing?.name);
    String? validation;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            existing == null ? 'Новая категория' : 'Название категории',
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: 'Например, Топ магической фантастики',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  final id = await widget.store.saveCategory(
                    controller.text,
                    id: existing?.id,
                  );
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  if (mounted) setState(() => category = id);
                } catch (e) {
                  if (context.mounted) update(() => validation = '$e');
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    // The route finishes its reverse animation before disposing field controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (mounted) await _load();
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final visible =
        shelf?.books
            .where(
              (b) =>
                  (category == null ||
                      (category == ''
                          ? b.categories.isEmpty
                          : b.categories.containsKey(category))) &&
                  '${b.catalog.title} ${b.catalog.authors.join(' ')} ${b.notes} ${strings(b.catalog.data['genres']).join(' ')}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
            )
            .toList() ??
        [];
    visible.sort((a, b) {
      if (category != null) {
        final rank = (a.categories[category] ?? 100000).compareTo(
          b.categories[category] ?? 100000,
        );
        if (rank != 0) return rank;
      }
      return a.catalog.title.toLowerCase().compareTo(
        b.catalog.title.toLowerCase(),
      );
    });
    final actions = [
      IconButton(
        tooltip: 'Источники поиска',
        onPressed: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => RecommendationSourcesPage(store: widget.store),
          ),
        ),
        icon: const Icon(Icons.manage_search),
      ),
      IconButton(
        tooltip: 'Копировать резервную копию подборок',
        onPressed: shelf == null
            ? null
            : () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent('  ')
                        .convert(shelf!.toJson()),
                  ),
                );
                if (mounted) {
                  _message('Копия подборок сохранена в буфер обмена (JSON)');
                }
              },
        icon: const Icon(Icons.copy_all),
      ),
    ];
    final body = loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _load,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ShelfIntro(
                title: 'Книжные рекомендации',
                subtitle:
                    '${shelf!.books.length} книг · ${shelf!.categories.length} категорий\nСобирайте советы, свои топы и планы на чтение.',
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _search,
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('Найти книгу в интернете'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить вручную'),
                  ),
                  TextButton.icon(
                    onPressed: _category,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Новая категория'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Поиск в моих подборках',
                ),
                onChanged: (value) => setState(() => query = value),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Все книги'),
                    selected: category == null,
                    onSelected: (_) => setState(() => category = null),
                  ),
                  for (final c in shelf!.categories)
                    ChoiceChip(
                      label: Text(
                        '${c.name} (${shelf!.books.where((b) => b.categories.containsKey(c.id)).length})',
                      ),
                      selected: category == c.id,
                      onSelected: (_) => setState(() => category = c.id),
                    ),
                  ChoiceChip(
                    label: const Text('Без категории'),
                    selected: category == '',
                    onSelected: (_) => setState(() => category = ''),
                  ),
                ],
              ),
              if (category != null && category!.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: PopupMenuButton<String>(
                    tooltip: 'Управление категорией',
                    onSelected: (value) async {
                      final selected = shelf!.categories.firstWhere(
                        (c) => c.id == category,
                      );
                      if (value == 'rename') {
                        await _category(existing: selected);
                      } else if (await _confirm(
                        'Удалить категорию?',
                        'Книги и заметки останутся в «Все книги».',
                      )) {
                        await _action(
                          () => widget.store.deleteCategory(selected.id),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text('Переименовать категорию'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить категорию'),
                      ),
                    ],
                    icon: const Icon(Icons.more_horiz),
                  ),
                ),
              const SizedBox(height: 18),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Column(
                    children: [
                      Icon(Icons.bookmarks_outlined, size: 48),
                      SizedBox(height: 12),
                      Text('Здесь пока нет книг'),
                      SizedBox(height: 8),
                      Text(
                        'Найдите книгу по названию или добавьте её вручную.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final book in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ShelfPanel(
                    child: InkWell(
                      onTap: () => _edit(book: book),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CatalogCover(book.catalog),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${category != null && book.categories[category] != null ? '#${book.categories[category]} · ' : ''}${book.catalog.title}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  if (book.catalog.authors.isNotEmpty)
                                    Text(book.catalog.authors.join(', ')),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: [
                                      for (final c in shelf!.categories.where(
                                        (c) =>
                                            book.categories.containsKey(c.id),
                                      ))
                                        Text(
                                          '${c.name}${book.categories[c.id] == null ? '' : ' · #${book.categories[c.id]}'}',
                                          style: TextStyle(
                                            color: ShelfPalette.of(context)
                                                .accent,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (book.notes.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        book.notes,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  const SizedBox(height: 6),
                                  Text(
                                    book.catalog.sourceLabel,
                                    style: TextStyle(
                                      color: ShelfPalette.of(context).muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Действия с рекомендацией',
                              onSelected: (value) async {
                                if (value == 'edit') {
                                  await _edit(book: book);
                                } else if (await _confirm(
                                  'Удалить рекомендацию?',
                                  'Книга «${book.catalog.title}» и заметка к ней будут удалены из подборок.',
                                )) {
                                  await _action(
                                    () => widget.store.deleteBook(book.id),
                                  );
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Открыть карточку'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Удалить рекомендацию'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          );
    if (widget.drawer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Рекомендации'), actions: actions),
        body: body,
      );
    }
    return ShelfShell(
      title: 'Рекомендации',
      drawer: widget.drawer!,
      sidebar: widget.sidebar,
      actions: actions,
      body: body,
    );
  }
}

class CatalogCover extends StatelessWidget {
  final CatalogBook book;
  const CatalogCover(this.book, {super.key});
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      width: 58,
      height: 82,
      child: book.coverUrl == null
          ? _placeholder(context)
          : Image.network(
              book.coverUrl!,
              fit: BoxFit.cover,
              cacheWidth: 180,
              errorBuilder: (_, _, _) => _placeholder(context),
            ),
    ),
  );
  Widget _placeholder(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.primaryContainer,
    child: const Center(child: Icon(Icons.menu_book_outlined)),
  );
}

class RecommendationSourcesPage extends StatefulWidget {
  final RecommendationStore store;
  const RecommendationSourcesPage({super.key, required this.store});
  @override
  State<RecommendationSourcesPage> createState() =>
      _RecommendationSourcesPageState();
}

class _RecommendationSourcesPageState extends State<RecommendationSourcesPage> {
  Set<String>? sources;
  String? error;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await widget.store.enabledSources();
      if (mounted) setState(() => sources = next);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Источники книжных данных')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Выбранные источники используются при поиске. Сохранённые карточки доступны без интернета.',
        ),
        const SizedBox(height: 20),
        if (sources == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (error != null) Text(error!),
        for (final entry in catalogSources.entries)
          SwitchListTile(
            title: Text(entry.value),
            subtitle: Text(switch (entry.key) {
              'inventaire' =>
                'Произведения, переводы, авторы и циклы. Без ключа.',
              'openlibrary' =>
                'Зарубежные книги, издания, ISBN и страницы. Без ключа.',
              _ => 'Русскоязычная фантастика. Гостевой API; поиск через сайт.',
            }),
            value: sources?.contains(entry.key) ?? false,
            onChanged: sources == null || saving
                ? null
                : (value) async {
                    final next = {...sources!};
                    value ? next.add(entry.key) : next.remove(entry.key);
                    setState(() => saving = true);
                    try {
                      await widget.store.setSources(next);
                      if (mounted) {
                        setState(() {
                          sources = next;
                          error = null;
                        });
                      }
                    } catch (e) {
                      if (mounted) setState(() => error = '$e');
                    } finally {
                      if (mounted) setState(() => saving = false);
                    }
                  },
          ),
        const SizedBox(height: 20),
        const Text(
          'По названию могут найтись разные тома и переводы. Проверяйте автора, цикл и издание перед добавлением. Неизвестные сведения остаются пустыми.',
        ),
      ],
    ),
  );
}

class RecommendationSearchPage extends StatefulWidget {
  final RecommendationStore store;
  final BookCatalog catalog;
  final String initialQuery;
  const RecommendationSearchPage({
    super.key,
    required this.store,
    required this.catalog,
    this.initialQuery = '',
  });
  @override
  State<RecommendationSearchPage> createState() =>
      _RecommendationSearchPageState();
}

class _RecommendationSearchPageState extends State<RecommendationSearchPage> {
  final query = TextEditingController();
  CatalogSearch? result;
  bool searching = false;
  String? loadingId, error;
  CatalogBook? incomplete;
  @override
  void initState() {
    super.initState();
    query.text = widget.initialQuery;
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (searching || loadingId != null) return;
    setState(() {
      searching = true;
      error = null;
      incomplete = null;
      result = null;
    });
    try {
      final sources = await widget.store.enabledSources();
      if (sources.isEmpty) {
        throw StateError('Включите хотя бы один источник поиска');
      }
      final next = await widget.catalog.search(query.text, sources);
      if (mounted) setState(() => result = next);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> _select(CatalogBook book) async {
    setState(() {
      loadingId = '${book.source}:${book.sourceId}';
      error = null;
      incomplete = null;
    });
    try {
      final full = await widget.catalog.details(book);
      if (mounted) Navigator.pop(context, full);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Не удалось получить полную карточку: $e';
          incomplete = book;
        });
      }
    } finally {
      if (mounted) setState(() => loadingId = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Поиск книги'),
      actions: [
        IconButton(
          tooltip: 'Источники поиска',
          icon: const Icon(Icons.tune),
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => RecommendationSourcesPage(store: widget.store),
            ),
          ),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: 'Название, автор, ISBN или ссылка Author.Today',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: searching || loadingId != null ? null : _search,
                  child: const Text('Искать'),
                ),
              ),
            ],
          ),
        ),
        if (searching || loadingId != null) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (incomplete != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, incomplete),
                  child: const Text(
                    'Добавить найденные данные без полной карточки',
                  ),
                ),
              for (final failure
                  in result?.failures.entries ?? <MapEntry<String, String>>[])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '${catalogSources[failure.key]}: ${failure.value}',
                  ),
                ),
              if (result != null && result!.books.isEmpty)
                const Text(
                  'Книг не найдено. Попробуйте оригинальное название или другого автора. Можно добавить книгу вручную.',
                ),
              if (result == null && !searching && error == null)
                const Text(
                  'Выберите нужную книгу из результатов. Перед сохранением откроется карточка с найденными сведениями.',
                ),
              for (final book in result?.books ?? <CatalogBook>[])
                Card(
                  child: ListTile(
                    isThreeLine: true,
                    leading: CatalogCover(book),
                    title: Text(book.title),
                    subtitle: Text(
                      [
                        if (book.authors.isNotEmpty) book.authors.join(', '),
                        book.sourceLabel,
                        if ('${book.data['publicationDate'] ?? ''}'.isNotEmpty)
                          '${book.data['publicationDate']}',
                        if ('${book.data['language'] ?? ''}'.isNotEmpty)
                          'Язык: ${book.data['language']}',
                        if (book.data['editionKey'] != null)
                          'Издание: ${book.data['editionKey']}',
                        if (book.data['shortDescription'] != null)
                          '${book.data['shortDescription']}',
                      ].join(' · '),
                    ),
                    onTap: loadingId != null || searching
                        ? null
                        : () => _select(book),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class RecommendationEditor extends StatefulWidget {
  final RecommendationStore store;
  final BookCatalog catalog;
  final List<RecommendationCategory> categories;
  final RecommendedBook? book;
  final CatalogBook? found;
  final String? initialCategory;
  const RecommendationEditor({
    super.key,
    required this.store,
    required this.catalog,
    required this.categories,
    this.book,
    this.found,
    this.initialCategory,
  });
  @override
  State<RecommendationEditor> createState() => _RecommendationEditorState();
}

class _RecommendationEditorState extends State<RecommendationEditor> {
  final form = GlobalKey<FormState>();
  final controllers = <String, TextEditingController>{};
  final ranks = <String, TextEditingController>{};
  final selected = <String>{};
  late CatalogBook catalog;
  bool busy = false;
  String? error;
  static const listFields = {'authors', 'genres', 'tags', 'isbn'};
  static const fields = {
    'title': 'Название',
    'authors': 'Авторы',
    'description': 'Аннотация',
    'genres': 'Жанры / темы источника',
    'tags': 'Теги',
    'series': 'Цикл / серия',
    'seriesNumber': 'Номер в серии',
    'publicationDate': 'Дата / год издания',
    'publisher': 'Издатель',
    'language': 'Язык',
    'pages': 'Страницы в выбранном издании',
    'isbn': 'ISBN',
    'coverUrl': 'Обложка (HTTPS-ссылка)',
  };
  @override
  void initState() {
    super.initState();
    catalog =
        widget.book?.catalog ??
        widget.found ??
        const CatalogBook(
          source: 'manual',
          sourceId: '',
          sourceUrl: '',
          data: {},
        );
    for (final key in fields.keys) {
      controllers[key] = TextEditingController(
        text: listFields.contains(key)
            ? strings(catalog.data[key]).join(', ')
            : '${catalog.data[key] ?? ''}',
      );
    }
    controllers['notes'] = TextEditingController(
      text: widget.book?.notes ?? '',
    );
    selected.addAll(widget.book?.categories.keys ?? <String>[]);
    if (widget.book == null &&
        widget.initialCategory != null &&
        widget.categories.any((c) => c.id == widget.initialCategory)) {
      selected.add(widget.initialCategory!);
    }
    for (final c in widget.categories) {
      ranks[c.id] = TextEditingController(
        text: '${widget.book?.categories[c.id] ?? ''}',
      );
    }
  }

  @override
  void dispose() {
    for (final c in [...controllers.values, ...ranks.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _enrich() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final full = await widget.catalog.details(catalog);
      if (!mounted) return;
      for (final key in fields.keys) {
        if (controllers[key]!.text.trim().isEmpty) {
          controllers[key]!.text = listFields.contains(key)
              ? strings(full.data[key]).join(', ')
              : '${full.data[key] ?? ''}';
        }
      }
      final merged = catalog.fillMissing(full);
      catalog = merged.withData({
        ...merged.data,
        'fetchWarnings': full.data['fetchWarnings'] ?? [],
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось дополнить карточку: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _lookup() async {
    final found = await Navigator.push<CatalogBook>(
      context,
      MaterialPageRoute(
        builder: (_) => RecommendationSearchPage(
          store: widget.store,
          catalog: widget.catalog,
          initialQuery: controllers['title']!.text,
        ),
      ),
    );
    if (!mounted || found == null) return;
    setState(() {
      for (final key in fields.keys) {
        if (controllers[key]!.text.trim().isEmpty) {
          controllers[key]!.text = listFields.contains(key)
              ? strings(found.data[key]).join(', ')
              : '${found.data[key] ?? ''}';
        }
      }
      catalog = found;
    });
  }

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = {...catalog.data};
      for (final entry in controllers.entries.where((e) => e.key != 'notes')) {
        final value = entry.value.text.trim();
        data[entry.key] = listFields.contains(entry.key)
            ? value == strings(catalog.data[entry.key]).join(', ')
                  ? strings(catalog.data[entry.key])
                  : value
                        .split(RegExp(r'[,;\n]'))
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toSet()
                        .toList()
            : entry.key == 'pages'
            ? int.tryParse(value)
            : value;
      }
      await widget.store.saveBook(
        RecommendedBook(
          id: widget.book?.id ?? uuid.v4(),
          catalog: catalog.withData(data),
          notes: controllers['notes']!.text,
          createdAt:
              widget.book?.createdAt ??
              DateTime.now().toUtc().toIso8601String(),
          categories: {
            for (final id in selected) id: int.tryParse(ranks[id]!.text.trim()),
          },
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(String key) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('recommendation-$key'),
      controller: controllers[key],
      enabled: !busy,
      minLines: key == 'description' ? 3 : 1,
      maxLines: key == 'description'
          ? 8
          : key == 'title'
          ? 3
          : 1,
      keyboardType: key == 'pages' ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: fields[key],
        helperText: listFields.contains(key)
            ? 'Через запятую или с новой строки'
            : null,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (key == 'title' && text.isEmpty) return 'Введите название';
        if (key == 'coverUrl' && text.isNotEmpty && safeWebUrl(text) == null) {
          return 'Введите общедоступную HTTPS-ссылку';
        }
        if (key == 'pages' &&
            text.isNotEmpty &&
            (int.tryParse(text) == null || int.parse(text) < 1)) {
          return 'Введите положительное число страниц';
        }
        return null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.book == null ? 'Добавить рекомендацию' : 'Карточка рекомендации',
      ),
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: busy ? null : _save,
          icon: const Icon(Icons.check),
          label: const Text('Сохранить рекомендацию'),
        ),
      ),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (catalog.source != 'manual') ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CatalogCover(catalog),
              title: Text(catalog.sourceLabel),
              subtitle: SelectableText(catalog.sourceUrl),
            ),
            if (catalog.data['editionKey'] != null)
              Text('Выбранное издание: ${catalog.data['editionKey']}'),
            TextButton.icon(
              onPressed: busy ? null : _enrich,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Заполнить пустые поля из источника'),
            ),
          ],
          if (catalog.source == 'manual')
            TextButton.icon(
              onPressed: busy ? null : _lookup,
              icon: const Icon(Icons.travel_explore),
              label: const Text('Найти сведения в интернете'),
            ),
          const SizedBox(height: 16),
          _field('title'),
          for (final warning in strings(catalog.data['fetchWarnings']))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                warning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _field('authors'),
          _field('description'),
          ExpansionTile(
            title: const Text('Другие сведения о книге'),
            children: [
              for (final key in fields.keys.where(
                (k) => !{'title', 'authors', 'description'}.contains(k),
              ))
                _field(key),
              if (catalog.data['textLength'] != null)
                ListTile(
                  title: const Text('Объём текста'),
                  subtitle: Text('${catalog.data['textLength']} знаков'),
                ),
              if (catalog.data['publicationFinished'] is bool)
                ListTile(
                  title: const Text('Публикация автора'),
                  subtitle: Text(
                    catalog.data['publicationFinished'] == true
                        ? 'Завершена'
                        : 'Продолжается',
                  ),
                ),
              if (catalog.data['shortDescription'] != null)
                Text('${catalog.data['shortDescription']}'),
              if (catalog.data['publicationCompletedAt'] != null)
                ListTile(
                  title: const Text('Завершение публикации автором'),
                  subtitle: Text('${catalog.data['publicationCompletedAt']}'),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Моя заметка', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('recommendation-notes'),
            controller: controllers['notes'],
            enabled: !busy,
            minLines: 3,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'Почему хочу прочитать / кто посоветовал',
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Категории и место в топе',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Можно выбрать несколько категорий. Место в топе необязательно.',
          ),
          for (final c in widget.categories)
            Column(
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name),
                  value: selected.contains(c.id),
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          value == true
                              ? selected.add(c.id)
                              : selected.remove(c.id);
                        }),
                ),
                if (selected.contains(c.id))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      key: ValueKey('rank-${c.id}'),
                      controller: ranks[c.id],
                      enabled: !busy,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Место в «${c.name}»',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) return null;
                        final rank = int.tryParse(value.trim());
                        return rank == null || rank < 1 || rank > 99999
                            ? 'Число от 1 до 99999'
                            : null;
                      },
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 20),
        ],
      ),
    ),
  );
}
