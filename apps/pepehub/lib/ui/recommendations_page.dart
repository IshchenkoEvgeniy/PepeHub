import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../sync/peer/app_sync_usage.dart';
import '../recommendations/book_catalog.dart';
import '../recommendations/recommendation_store.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';

class RecommendationsPage extends StatefulWidget {
  final RecommendationStore store;
  final BookCatalog catalog;
  final ShelfNavigation? navigation;
  const RecommendationsPage({
    super.key,
    required this.store,
    required this.catalog,
    this.navigation,
  });
  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  void Function()? _releaseSync;
  RecommendationShelf? shelf;
  String? category, error;
  final queryController = TextEditingController();
  String get query => queryController.text.trim();
  RecommendationSort? sort;
  bool changing = false;
  bool get hasCategory => category != null && category!.isNotEmpty;
  RecommendationSort get effectiveSort =>
      sort == RecommendationSort.top && !hasCategory
      ? RecommendationSort.title
      : sort ??
            (hasCategory ? RecommendationSort.top : RecommendationSort.title);
  bool get canReorder =>
      hasCategory &&
      query.isEmpty &&
      effectiveSort == RecommendationSort.top &&
      !changing;

  @override
  void dispose() {
    _releaseSync?.call();
    widget.store.repository.externalChanges.removeListener(_load);
    queryController.dispose();
    super.dispose();
  }

  String? selectedId;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    _releaseSync = AppSyncUsage.hold(
      widget.store.repository.db,
      'recommendations',
    );
    widget.store.repository.externalChanges.addListener(_load);
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
    if (changing) return;
    setState(() => changing = true);
    try {
      await action();
      if (mounted) await _load();
    } catch (e) {
      if (mounted) _message('$e');
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  Future<void> _view(RecommendedBook book) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RecommendationDetailPage(
          store: widget.store,
          catalog: widget.catalog,
          book: book,
          categories: shelf!.categories,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _chooseCategories(RecommendedBook book) async {
    final selected = book.categories.keys.toSet();
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('В подборки'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(book.catalog.title),
                  const SizedBox(height: 12),
                  for (final c in shelf!.categories)
                    CheckboxListTile(
                      key: ValueKey('quick-category-${c.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.name),
                      value: selected.contains(c.id),
                      onChanged: saving
                          ? null
                          : (value) => update(() {
                              value == true
                                  ? selected.add(c.id)
                                  : selected.remove(c.id);
                            }),
                    ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      update(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await widget.store.setBookCategories(book.id, selected);
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
                          Navigator.pop(dialogContext);
                        }
                      } catch (e) {
                        if (dialogContext.mounted) update(() => error = '$e');
                      } finally {
                        if (dialogContext.mounted) update(() => saving = false);
                      }
                    },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (mounted) await _load();
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
                  if (!context.mounted ||
                      ModalRoute.of(context)?.isCurrent != true) {
                    return;
                  }
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

  Future<void> _categoryMenu(String value) async {
    final selected = shelf!.categories.firstWhere((c) => c.id == category);
    if (value == 'rename') {
      await _category(existing: selected);
    } else if (await _confirm(
      'Удалить категорию?',
      'Книги и заметки останутся в «Все книги».',
    )) {
      await _action(() => widget.store.deleteCategory(selected.id));
    }
  }

  Future<void> _bookMenu(RecommendedBook book, String value) async {
    if (value == 'view') {
      await _view(book);
    } else if (value == 'edit') {
      await _edit(book: book);
    } else if (value == 'categories') {
      await _chooseCategories(book);
    } else if (value == 'up' || value == 'down') {
      if (!canReorder) return;
      final id = category!;
      await _action(
        () => widget.store.moveInTop(id, book.id, value == 'up' ? -1 : 1),
      );
    } else if (await _confirm(
      'Удалить рекомендацию?',
      'Книга «${book.catalog.title}» и заметка к ней будут удалены из подборок.',
    )) {
      await _action(() => widget.store.deleteBook(book.id));
    }
  }

  Widget _bookMenuButton(RecommendedBook book, int index, int count) =>
      PopupMenuButton<String>(
        key: ValueKey('recommendation-menu-${book.id}'),
        tooltip: 'Действия с рекомендацией',
        onSelected: (value) => _bookMenu(book, value),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'view', child: Text('Посмотреть')),
          const PopupMenuItem(value: 'edit', child: Text('Редактировать')),
          const PopupMenuItem(value: 'categories', child: Text('В подборки')),
          if (canReorder) ...[
            PopupMenuItem(
              value: 'up',
              enabled: index > 0,
              child: const Text('Поднять'),
            ),
            PopupMenuItem(
              value: 'down',
              enabled: index < count - 1,
              child: const Text('Опустить'),
            ),
          ],
          const PopupMenuItem(
            value: 'delete',
            child: Text('Удалить рекомендацию'),
          ),
        ],
      );

  Widget _categoryMenuButton() => PopupMenuButton<String>(
    tooltip: 'Управление категорией',
    onSelected: _categoryMenu,
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'rename', child: Text('Переименовать категорию')),
      PopupMenuItem(value: 'delete', child: Text('Удалить категорию')),
    ],
    icon: const Icon(Icons.more_horiz),
  );

  Widget _row(
    ShelfPalette palette,
    RecommendedBook book,
    bool wide,
    int index,
    int count,
  ) {
    final rank = category != null && category!.isNotEmpty
        ? book.categories[category]
        : null;
    final active = wide && selectedId == book.id;
    return Padding(
      key: ValueKey('recommendation-row-${book.id}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? palette.selected : palette.panel,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: wide
              ? () => setState(() => selectedId = book.id)
              : () => _view(book),
          onDoubleTap: wide ? () => _edit(book: book) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (canReorder)
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6, top: 8),
                      child: Tooltip(
                        message: 'Перетащить в топе',
                        child: Icon(
                          Icons.drag_handle,
                          color: palette.muted,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                if (rank != null)
                  SizedBox(
                    width: wide ? 64 : 44,
                    child: Text(
                      '$rank',
                      style: AppFonts.title(
                        rank <= 3 ? palette.accent : palette.muted,
                        size: wide ? 40 : 28,
                      ),
                    ),
                  ),
                CatalogCover(book.catalog, width: wide ? 60 : 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.catalog.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.book(palette.text, size: 18),
                      ),
                      if (book.catalog.authors.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            book.catalog.authors.join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: palette.muted,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          for (final c in shelf!.categories.where(
                            (c) => book.categories.containsKey(c.id),
                          ))
                            Text(
                              '${c.name}${book.categories[c.id] == null ? '' : ' · #${book.categories[c.id]}'}',
                              style: TextStyle(
                                color: palette.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            book.catalog.sourceLabel,
                            style: TextStyle(
                              color: palette.muted,
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: palette.text.withValues(alpha: .82),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                _bookMenuButton(book, index, count),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _categoryRow(
    ShelfPalette palette,
    String label,
    int count,
    bool active,
    VoidCallback onTap,
  ) => Material(
    color: active ? palette.selected : Colors.transparent,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? palette.text : palette.text,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _categories(ShelfPalette palette) => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      const PepeCaption('Категории'),
      const SizedBox(height: 8),
      _categoryRow(
        palette,
        'Все книги',
        shelf!.books.length,
        category == null,
        () => setState(() => category = null),
      ),
      for (final c in shelf!.categories)
        _categoryRow(
          palette,
          c.name,
          shelf!.books.where((b) => b.categories.containsKey(c.id)).length,
          category == c.id,
          () => setState(() => category = c.id),
        ),
      _categoryRow(
        palette,
        'Без категории',
        shelf!.books.where((b) => b.categories.isEmpty).length,
        category == '',
        () => setState(() => category = ''),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _category,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Новая категория'),
        ),
      ),
    ],
  );

  Widget _detail(ShelfPalette palette, RecommendedBook? book) {
    if (book == null) {
      return PepePanel(
        outlined: true,
        child: Text(
          'Выберите книгу в списке, чтобы увидеть описание и заметку. Двойное нажатие открывает карточку.',
          style: TextStyle(fontSize: 13, height: 1.45, color: palette.muted),
        ),
      );
    }
    return SingleChildScrollView(
      child: RecommendationDetails(
        book: book,
        categories: shelf!.categories,
        compact: true,
        onEdit: () => _edit(book: book),
        onDelete: () => _bookMenu(book, 'delete'),
      ),
    );
  }

  void _resetQuery() => setState(queryController.clear);

  String _sortLabel(RecommendationSort value) => switch (value) {
    RecommendationSort.top => 'По месту в топе',
    RecommendationSort.title => 'По названию',
    RecommendationSort.recent => 'Недавно добавленные',
    RecommendationSort.author => 'По автору',
  };

  Widget _sortControl() => DropdownButtonFormField<RecommendationSort>(
    key: ValueKey('recommendation-sort-${effectiveSort.name}'),
    initialValue: effectiveSort,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Сортировка'),
    items: [
      for (final value in RecommendationSort.values)
        if (value != RecommendationSort.top || hasCategory)
          DropdownMenuItem(value: value, child: Text(_sortLabel(value))),
    ],
    onChanged: changing ? null : (value) => setState(() => sort = value),
  );

  Widget _empty(ShelfPalette palette) {
    final searching = query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          Icon(
            searching ? Icons.search_off : Icons.bookmarks_outlined,
            size: 48,
            color: palette.muted,
          ),
          const SizedBox(height: 12),
          Text(
            searching
                ? 'Ничего не найдено'
                : category == ''
                ? 'Нет книг без категории'
                : hasCategory
                ? 'Подборка пуста'
                : 'Подборки пока пусты',
          ),
          const SizedBox(height: 8),
          Text(
            searching
                ? 'Попробуйте другое название, автора или заметку.'
                : category == ''
                ? 'Все сохранённые книги уже распределены по подборкам.'
                : 'Найдите книгу в интернете или добавьте её вручную.',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted),
          ),
          if (searching)
            TextButton(onPressed: _resetQuery, child: const Text('Сбросить')),
        ],
      ),
    );
  }

  Widget _bookList(
    ShelfPalette palette,
    List<RecommendedBook> books,
    bool wide, {
    required Widget header,
    required EdgeInsets padding,
  }) {
    if (!canReorder) {
      return ListView.builder(
        padding: padding,
        itemCount: books.length + 1,
        itemBuilder: (_, index) => index == 0
            ? header
            : _row(palette, books[index - 1], wide, index - 1, books.length),
      );
    }
    final categoryId = category!;
    return ReorderableListView.builder(
      padding: padding,
      buildDefaultDragHandles: false,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Перетащите книгу или выберите «Поднять / Опустить». '
              'Места в этой подборке будут пронумерованы заново.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      itemCount: books.length,
      itemBuilder: (_, index) =>
          _row(palette, books[index], wide, index, books.length),
      onReorderItem: (oldIndex, newIndex) {
        final ids = books.map((b) => b.id).toList();
        if (oldIndex == newIndex) return;
        ids.insert(newIndex, ids.removeAt(oldIndex));
        _action(() => widget.store.reorderTop(categoryId, ids));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
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
    visible.sort(
      (a, b) =>
          compareRecommendations(a, b, sort: effectiveSort, category: category),
    );
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
    final buttons = Wrap(
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
      ],
    );
    final search = TextField(
      controller: queryController,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        labelText: 'Поиск в моих подборках',
        suffixIcon: queryController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Сбросить поиск',
                onPressed: _resetQuery,
                icon: const Icon(Icons.close),
              ),
      ),
      onChanged: (_) => setState(() {}),
    );
    final empty = _empty(palette);
    final currentName = category == null
        ? 'Все книги'
        : category == ''
        ? 'Без категории'
        : shelf?.categories.where((c) => c.id == category).firstOrNull?.name ??
              'Подборка';

    Widget content(double width) {
      final wide = width >= 860, detail = width >= 1180;
      if (loading) return const Center(child: CircularProgressIndicator());
      if (error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('Повторить')),
              ],
            ),
          ),
        );
      }
      if (!wide) {
        return _bookList(
          palette,
          visible,
          false,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${shelf!.books.length} книг · ${shelf!.categories.length} категорий · свои топы и планы на чтение',
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
              const SizedBox(height: 16),
              buttons,
              const SizedBox(height: 16),
              search,
              const SizedBox(height: 14),
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
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: const Text('Новая категория'),
                    onPressed: _category,
                  ),
                ],
              ),
              if (category != null && category!.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: _categoryMenuButton(),
                ),
              const SizedBox(height: 14),
              _sortControl(),
              const SizedBox(height: 14),
              if (visible.isEmpty) empty,
            ],
          ),
        );
      }
      final current = visible.where((b) => b.id == selectedId).firstOrNull;
      return Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 230, child: _categories(palette)),
            const SizedBox(width: 24),
            Expanded(
              child: _bookList(
                palette,
                visible,
                detail,
                padding: const EdgeInsets.only(bottom: 28),
                header: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            currentName,
                            style: AppFonts.title(palette.text, size: 30),
                          ),
                        ),
                        if (category != null && category!.isNotEmpty)
                          _categoryMenuButton(),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${visible.length} книг · ${_sortLabel(effectiveSort).toLowerCase()}',
                      style: TextStyle(fontSize: 13, color: palette.muted),
                    ),
                    const SizedBox(height: 16),
                    search,
                    const SizedBox(height: 12),
                    buttons,
                    const SizedBox(height: 12),
                    _sortControl(),
                    const SizedBox(height: 18),
                    if (visible.isEmpty) empty,
                  ],
                ),
              ),
            ),
            if (detail) ...[
              const SizedBox(width: 24),
              SizedBox(
                width: 360,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _detail(palette, current),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (widget.navigation == null) {
      return PepeSubpage(
        title: 'Рекомендации',
        section: PepeSection.recommendations,
        actions: actions,
        maxWidth: 1600,
        body: LayoutBuilder(builder: (context, c) => content(c.maxWidth)),
      );
    }
    return ShelfShell(
      title: 'Рекомендации',
      navigation: widget.navigation!,
      actions: actions,
      body: LayoutBuilder(builder: (context, c) => content(c.maxWidth)),
    );
  }
}

class RecommendationDetails extends StatelessWidget {
  final RecommendedBook book;
  final List<RecommendationCategory> categories;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool compact;
  const RecommendationDetails({
    super.key,
    required this.book,
    required this.categories,
    required this.onEdit,
    this.onDelete,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final description = '${book.catalog.data['description'] ?? ''}'.trim();
    final genres = strings(book.catalog.data['genres']);
    return PepePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CatalogCover(book.catalog, width: 96),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.catalog.title,
                      style: AppFonts.book(palette.text, size: 21),
                    ),
                    if (book.catalog.authors.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          book.catalog.authors.join(', '),
                          style: TextStyle(fontSize: 13, color: palette.muted),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      book.catalog.sourceLabel,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final g in genres.take(6)) ShelfPill(label: g)],
            ),
          ],
          if (description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              description,
              maxLines: compact ? 9 : null,
              overflow: compact ? TextOverflow.ellipsis : TextOverflow.visible,
              style: TextStyle(fontSize: 13, height: 1.5, color: palette.text),
            ),
          ],
          const SizedBox(height: 16),
          const PepeCaption('Моя заметка'),
          const SizedBox(height: 6),
          Text(
            book.notes.isEmpty ? 'Заметки нет' : book.notes,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              color: book.notes.isEmpty ? palette.muted : palette.text,
            ),
          ),
          if (book.categories.isNotEmpty) ...[
            const SizedBox(height: 16),
            const PepeCaption('В подборках'),
            const SizedBox(height: 6),
            for (final c in categories.where(
              (c) => book.categories.containsKey(c.id),
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(c.name)),
                    Text(
                      book.categories[c.id] == null
                          ? '—'
                          : '#${book.categories[c.id]}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: palette.accent,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onEdit != null)
                FilledButton(
                  onPressed: onEdit,
                  child: const Text('Редактировать'),
                ),
              if (onDelete != null)
                OutlinedButton(
                  onPressed: onDelete,
                  child: const Text('Удалить'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class RecommendationDetailPage extends StatefulWidget {
  final RecommendationStore store;
  final BookCatalog catalog;
  final RecommendedBook book;
  final List<RecommendationCategory> categories;
  const RecommendationDetailPage({
    super.key,
    required this.store,
    required this.catalog,
    required this.book,
    required this.categories,
  });
  @override
  State<RecommendationDetailPage> createState() =>
      _RecommendationDetailPageState();
}

class _RecommendationDetailPageState extends State<RecommendationDetailPage> {
  late RecommendedBook book = widget.book;
  late List<RecommendationCategory> categories = widget.categories;
  bool opening = false;
  Future<void> _edit() async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final current = await widget.store.load();
      final live = current.books.where((b) => b.id == book.id).firstOrNull;
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (live == null) throw StateError('Рекомендация удалена');
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => RecommendationEditor(
            store: widget.store,
            catalog: widget.catalog,
            categories: current.categories,
            book: live,
          ),
        ),
      );
      final next = await widget.store.load();
      if (!mounted) return;
      final updated = next.books.where((b) => b.id == book.id).firstOrNull;
      if (updated != null) {
        setState(() {
          book = updated;
          categories = next.categories;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => PepeSubpage(
    title: 'Рекомендация',
    back: 'Рекомендации',
    section: PepeSection.recommendations,
    maxWidth: 860,
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: opening ? null : _edit,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Редактировать'),
        ),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (opening) const LinearProgressIndicator(),
        RecommendationDetails(book: book, categories: categories, onEdit: null),
      ],
    ),
  );
}

class CatalogCover extends StatelessWidget {
  final CatalogBook book;
  final double width;
  const CatalogCover(this.book, {super.key, this.width = 58});
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(width > 80 ? 12 : 6),
    child: SizedBox(
      width: width,
      height: width * 1.42,
      child: book.coverUrl == null
          ? _placeholder(context)
          : Image.network(
              book.coverUrl!,
              fit: BoxFit.cover,
              cacheWidth: (width * 3).round(),
              errorBuilder: (_, _, _) => _placeholder(context),
            ),
    ),
  );
  Widget _placeholder(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return ColoredBox(
      color: palette.raised,
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          size: width / 2.6,
          color: palette.muted,
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) => PepeSubpage(
    title: 'Источники',
    back: 'Рекомендации',
    section: PepeSection.recommendations,
    maxWidth: 900,
    subtitle: 'Выбранные источники используются при поиске. Сохранённые карточки доступны без интернета.',
    children: [
      const SizedBox(height: 4),
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
      Text(
        'По названию могут найтись разные тома и переводы. Проверяйте автора, цикл и издание перед добавлением. Неизвестные сведения остаются пустыми.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: ShelfPalette.of(context).muted,
        ),
      ),
    ],
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
  int searchGeneration = 0;
  String searchedQuery = '';
  Set<String> searchedSources = {};
  final pendingSources = <String>{};
  Set<String> savedCards = {};
  bool _saved(CatalogBook book) =>
      savedCards.contains('${book.source}:${book.sourceId}');
  @override
  void initState() {
    super.initState();
    query.text = widget.initialQuery;
    _loadSources();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void _acceptProgress(CatalogSearch next, Set<String> completed) {
    final previous = result ?? const CatalogSearch([], {});
    final combined = [
      ...previous.books.where((b) => !completed.contains(b.source)),
      ...next.books.where((b) => completed.contains(b.source)),
    ]..sort((a, b) => compareCatalogBooks(a, b, searchedQuery));
    result = CatalogSearch(
      List.unmodifiable(combined),
      {
        for (final entry in previous.failures.entries)
          if (!completed.contains(entry.key)) entry.key: entry.value,
        for (final entry in next.failures.entries)
          if (completed.contains(entry.key)) entry.key: entry.value,
      },
      completedSources: {...previous.completedSources, ...completed},
    );
    pendingSources.removeAll(completed);
    searching = pendingSources.isNotEmpty;
  }

  Future<void> _search() async {
    if (searching || loadingId != null) return;
    final generation = ++searchGeneration;
    final text = query.text.trim();
    setState(() {
      searching = true;
      error = null;
      incomplete = null;
      result = null;
      searchedSources = {};
      searchedQuery = text;
      pendingSources.clear();
    });
    try {
      final enabled = await widget.store.enabledSources();
      if (enabled.isEmpty) {
        throw StateError('Включите хотя бы один источник поиска');
      }
      if (!mounted || generation != searchGeneration) return;
      setState(() {
        searchedSources = enabled;
        pendingSources.addAll(enabled);
      });
      // Later aggregate snapshots include earlier failures. Only accept newly
      // finished providers so they cannot undo an independent retry.
      final completed = <String>{};
      await widget.catalog.search(
        text,
        enabled,
        onProgress: (progress) {
          final newlyCompleted = progress.completedSources.difference(
            completed,
          );
          completed.addAll(newlyCompleted);
          if (mounted && generation == searchGeneration) {
            setState(() => _acceptProgress(progress, newlyCompleted));
          }
        },
      );
    } catch (e) {
      if (mounted && generation == searchGeneration) {
        setState(() {
          error = '$e';
          searchedSources = {};
          pendingSources.clear();
        });
      }
    } finally {
      if (mounted && generation == searchGeneration) {
        setState(() => searching = pendingSources.isNotEmpty);
      }
    }
  }

  Future<void> _retrySource(String source) async {
    if (pendingSources.contains(source) ||
        loadingId != null ||
        searchedQuery.isEmpty ||
        result == null) {
      return;
    }
    final generation = searchGeneration;
    final previous = result!;
    setState(() {
      pendingSources.add(source);
      searching = true;
      error = null;
      incomplete = null;
      result = CatalogSearch(
        previous.books,
        {...previous.failures}..remove(source),
        completedSources: {...previous.completedSources}..remove(source),
      );
    });
    try {
      await widget.catalog.search(
        searchedQuery,
        {source},
        onProgress: (progress) {
          if (mounted && generation == searchGeneration) {
            setState(() => _acceptProgress(progress, {source}));
          }
        },
      );
    } catch (e) {
      if (mounted && generation == searchGeneration) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && generation == searchGeneration) {
        setState(() {
          pendingSources.remove(source);
          searching = pendingSources.isNotEmpty;
        });
      }
    }
  }

  Future<void> _select(CatalogBook book) async {
    if (loadingId != null) return;
    setState(() {
      loadingId = '${book.source}:${book.sourceId}';
      error = null;
      incomplete = null;
    });
    try {
      final full = await widget.catalog.details(book);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, full);
      }
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

  Set<String>? sources;

  Future<void> _loadSources() async {
    try {
      final next = await widget.store.enabledSources();
      final shelf = await widget.store.load();
      if (mounted) {
        setState(() {
          sources = next;
          savedCards = {
            for (final b in shelf.books)
              if (b.catalog.sourceId.isNotEmpty)
                '${b.catalog.source}:${b.catalog.sourceId}',
          };
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Не удалось прочитать настройки поиска: $e');
      }
    }
  }

  Widget _sourceStatus(String source, ShelfPalette palette) {
    final complete = result?.completedSources.contains(source) ?? false;
    final failure = result?.failures[source];
    final count = result?.books.where((b) => b.source == source).length ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${catalogSources[source]} · ${!complete && searching
                      ? 'Ищет…'
                      : failure != null
                      ? 'Ошибка'
                      : 'Найдено: $count'}',
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
                if (failure != null)
                  Text(
                    failure,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          if (failure != null)
            TextButton.icon(
              key: ValueKey('retry-$source'),
              onPressed: pendingSources.contains(source) || loadingId != null
                  ? null
                  : () => _retrySource(source),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Повторить'),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleSource(String key) async {
    final current = sources;
    if (current == null) return;
    final next = {...current};
    next.contains(key) ? next.remove(key) : next.add(key);
    setState(() => sources = next);
    try {
      await widget.store.setSources(next);
    } catch (e) {
      if (mounted) {
        setState(() {
          sources = current;
          error = '$e';
        });
      }
    }
  }

  String _details(CatalogBook book) => [
    if (_saved(book)) 'Уже в подборках',
    if (book.authors.isNotEmpty) book.authors.join(', '),
    book.sourceLabel,
    if ('${book.data['publicationDate'] ?? ''}'.isNotEmpty)
      '${book.data['publicationDate']}',
    if (book.data['firstPublicationYear'] != null)
      'Первое издание: ${book.data['firstPublicationYear']}',
    if ('${book.data['language'] ?? ''}'.isNotEmpty)
      'Язык: ${book.data['language']}',
    if (book.data['editionKey'] != null) 'Издание: ${book.data['editionKey']}',
    if (book.data['shortDescription'] != null)
      '${book.data['shortDescription']}',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final busy = searching || loadingId != null;
    final books = result?.books ?? <CatalogBook>[];
    final field = TextField(
      controller: query,
      autofocus: true,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      maxLength: 300,
      style: AppFonts.book(palette.text, size: 20),
      decoration: const InputDecoration(
        labelText: 'Название, автор, ISBN или ссылка Author.Today',
        prefixIcon: Icon(Icons.search),
        counterText: '',
      ),
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < 560
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: busy ? null : _search,
                      child: const Text('Искать'),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: busy ? null : _search,
                        child: const Text('Искать'),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Источники:',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
            for (final entry in catalogSources.entries)
              ShelfPill(
                label: entry.value,
                selected: sources?.contains(entry.key) ?? false,
                onTap: sources == null || busy
                    ? null
                    : () => _toggleSource(entry.key),
              ),
          ],
        ),
      ],
    );
    return PepeSubpage(
      title: 'Поиск книги',
      back: 'Рекомендации',
      section: PepeSection.recommendations,
      maxWidth: 1100,
      actions: [
        IconButton(
          tooltip: 'Источники поиска',
          icon: const Icon(Icons.tune),
          onPressed: busy
              ? null
              : () async {
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          RecommendationSourcesPage(store: widget.store),
                    ),
                  );
                  if (mounted) _loadSources();
                },
        ),
      ],
      body: LayoutBuilder(
        builder: (context, c) {
          final pad = c.maxWidth >= 700 ? 28.0 : 16.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: header,
              ),
              const SizedBox(height: 12),
              if (busy) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(pad, 8, pad, 24),
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (incomplete != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Navigator.pop(context, incomplete),
                          child: const Text(
                            'Добавить найденные данные без полной карточки',
                          ),
                        ),
                      ),
                    if (searchedSources.isNotEmpty) ...[
                      Text(
                        'Результаты для «$searchedQuery»',
                        style: TextStyle(fontSize: 12.5, color: palette.muted),
                      ),
                      const SizedBox(height: 10),
                      for (final source in catalogSources.keys.where(
                        searchedSources.contains,
                      ))
                        _sourceStatus(source, palette),
                    ],
                    if (result != null && books.isEmpty && !searching)
                      Text(
                        'Книг не найдено. Попробуйте оригинальное название или другого автора. Можно добавить книгу вручную.',
                        style: TextStyle(color: palette.muted),
                      ),
                    if (result == null && !searching && error == null)
                      Text(
                        'Выберите нужную книгу из результатов. Перед сохранением откроется карточка с найденными сведениями.',
                        style: TextStyle(color: palette.muted),
                      ),
                    if (books.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: PepeCaption('Найдено: ${books.length}'),
                      ),
                    for (final book in books)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: loadingId == '${book.source}:${book.sourceId}'
                              ? palette.selected
                              : palette.panel,
                          borderRadius: BorderRadius.circular(18),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            isThreeLine: true,
                            contentPadding: const EdgeInsets.fromLTRB(
                              14,
                              8,
                              14,
                              8,
                            ),
                            leading: CatalogCover(book),
                            title: Text(
                              book.title,
                              style: AppFonts.book(palette.text, size: 18),
                            ),
                            subtitle: Text(
                              _details(book),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Icon(
                              _saved(book)
                                  ? Icons.check_circle_outline
                                  : Icons.add_circle_outline,
                            ),
                            onTap: loadingId != null
                                ? null
                                : () => _select(book),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
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
  final listValues = <String, List<String>>{};
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
      if (listFields.contains(key)) {
        listValues[key] = strings(catalog.data[key]);
      }
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
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final full = await widget.catalog.details(
        catalog.withData({
          if (catalog.data['editionKey'] != null)
            'editionKey': catalog.data['editionKey'],
        }),
      );
      if (!mounted) return;
      for (final key in fields.keys) {
        if (controllers[key]!.text.trim().isEmpty) {
          controllers[key]!.text = listFields.contains(key)
              ? strings(full.data[key]).join(', ')
              : '${full.data[key] ?? ''}';
          if (listFields.contains(key)) {
            listValues[key] = strings(full.data[key]);
          }
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
          if (listFields.contains(key)) {
            listValues[key] = strings(found.data[key]);
          }
        }
      }
      catalog = found;
    });
  }

  Future<void> _save() async {
    if (busy) return;
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
            ? value == (listValues[entry.key] ?? []).join(', ')
                  ? listValues[entry.key] ?? <String>[]
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
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
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
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final main = PepePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (catalog.source != 'manual') ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CatalogCover(catalog, width: 72),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        catalog.sourceLabel,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        catalog.sourceUrl,
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                      if (catalog.data['editionKey'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Выбранное издание: ${catalog.data['editionKey']}',
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : _enrich,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Заполнить пустые поля из источника'),
              ),
            ),
          ],
          if (catalog.source == 'manual')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : _lookup,
                icon: const Icon(Icons.travel_explore),
                label: const Text('Найти сведения в интернете'),
              ),
            ),
          const SizedBox(height: 12),
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
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
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
                if (catalog.data['firstPublicationYear'] != null)
                  ListTile(
                    title: const Text('Первое издание произведения'),
                    subtitle: Text('${catalog.data['firstPublicationYear']}'),
                  ),
                if (catalog.data['publicationCompletedAt'] != null)
                  ListTile(
                    title: const Text('Завершение публикации автором'),
                    subtitle: Text('${catalog.data['publicationCompletedAt']}'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final mine = PepePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PepeHeading('Моя заметка'),
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
          const PepeHeading('Категории и место в топе'),
          const SizedBox(height: 6),
          Text(
            'Можно выбрать несколько категорий. Место в топе необязательно.',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
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
                        prefixText: '#',
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
        ],
      ),
    );
    return PepeSubpage(
      title: widget.book == null
          ? 'Добавить рекомендацию'
          : 'Карточка рекомендации',
      back: 'Рекомендации',
      section: PepeSection.recommendations,
      maxWidth: 1240,
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: FilledButton.icon(
              onPressed: busy ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('Сохранить рекомендацию'),
            ),
          ),
        ),
      ),
      body: Form(
        key: form,
        child: LayoutBuilder(
          builder: (context, c) {
            final pad = c.maxWidth >= 700 ? 28.0 : 16.0;
            return ListView(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
              children: [
                if (busy) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                PepeRow(breakpoint: 860, children: [(6, main), (5, mine)]),
              ],
            );
          },
        ),
      ),
    );
  }
}
