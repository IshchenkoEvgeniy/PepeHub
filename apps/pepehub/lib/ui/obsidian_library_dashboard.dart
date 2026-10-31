import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import 'library_data_page.dart';
import 'library_work_page.dart';
import 'library_cover_search.dart';
import 'library_groups_page.dart';
import 'library_batch_actions.dart';
import '../library/library_features.dart';
import 'obsidian_notes_page.dart';
import 'library_card_actions.dart';
import 'library_trash_page.dart';
import 'library_audio_time_sheet.dart';
import 'activity_page.dart';
import 'app_theme.dart';
import 'obsidian_library_page.dart' show LibraryMetadataEditor, libraryState;
import 'shelf_components.dart';

num? _number(dynamic value) {
  final result = value is num ? value : num.tryParse('$value');
  return result?.isFinite == true ? result : null;
}

String _text(dynamic value) =>
    value is List ? value.join(', ') : '${value ?? ''}';
String _amount(num? value) => value == null
    ? '—'
    : value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

String metadataReadingStatus(ObsidianLibraryItem item) {
  final status = _text(item.value('status')).toLowerCase().trim();
  final canonical = libraryStatus(item);
  if (['paused', 'abandoned'].contains(canonical)) return canonical;
  if ([
    'finished',
    'completed',
    'done',
    'завершено',
    'завершённые',
    'завершен',
    'прочитано',
    'прослушано',
  ].contains(status)) {
    return 'finished';
  }
  if ([
    'active',
    'reading',
    'listening',
    'in progress',
    'в процессе',
    'читаю',
    'чтение',
    'слушаю',
    'прослушивание',
    'слушание',
    'начато',
  ].contains(status)) {
    return 'active';
  }
  if ([
    'planned',
    'new',
    'to read',
    'в планах',
    'запланировано',
    'новая',
    'не начато',
  ].contains(status)) {
    return 'planned';
  }
  if (status.isEmpty) {
    final progress = _number(item.value('progress')),
        total = _number(item.value('total'));
    if (progress != null && progress > 0) {
      return total != null && total > 0 && progress >= total
          ? 'finished'
          : 'active';
    }
  }
  return 'other';
}

double? metadataProgress(ObsidianLibraryItem item) {
  final total = _number(item.value('total')),
      progress = _number(item.value('progress'));
  if (total == null ||
      total <= 0 ||
      progress == null ||
      !total.isFinite ||
      !progress.isFinite) {
    return null;
  }
  return (progress / total).clamp(0.0, 1.0);
}

String _duration(num value) {
  final total = (value * 60).round(),
      hours = total ~/ 3600,
      minutes = total ~/ 60 % 60,
      seconds = total % 60;
  return [
    if (hours > 0) '$hours ч',
    if (minutes > 0) '$minutes мин',
    if (seconds > 0) '$seconds с',
    if (total == 0) '0 мин',
  ].join(' ');
}

String metadataProgressLabel(ObsidianLibraryItem item) {
  final total = _number(item.value('total')),
      progress = _number(item.value('progress'));
  final unit = _text(item.value('unit'));
  if (total == null && progress == null) return 'Прогресс не указан';
  if (unit == 'percent') {
    return progress == null ? 'Прогресс не указан' : '${_amount(progress)}%';
  }
  if (item.mediaType == 'audiobook' &&
      (unit.isEmpty ||
          [
            'minutes',
            'minute',
            'мин',
            'минуты',
            'hours',
          ].contains(unit.toLowerCase()))) {
    final factor = unit.toLowerCase() == 'hours' ? 60 : 1;
    return progress == null
        ? _duration(total! * factor)
        : total == null
        ? _duration(progress * factor)
        : '${_duration(progress * factor)} / ${_duration(total * factor)}';
  }
  final label = unit.isEmpty || unit == 'pages' ? 'стр.' : unit;
  return progress == null
      ? '${_amount(total)} $label'
      : total == null
      ? '${_amount(progress)} $label'
      : '${_amount(progress)} / ${_amount(total)} $label';
}

class ShelfBookCover extends StatelessWidget {
  final String title, mediaType;
  final String? cover, localPath;
  final double width, height;
  const ShelfBookCover({
    super.key,
    required this.title,
    required this.mediaType,
    this.cover,
    this.localPath,
    this.width = 40,
    this.height = 60,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final uri = Uri.tryParse(cover ?? '');
    final usable =
        uri != null &&
        uri.userInfo.isEmpty &&
        ['https', 'http'].contains(uri.scheme);
    final tones = [
      const Color(0xff514875),
      const Color(0xff35545e),
      const Color(0xff66523d),
      const Color(0xff405747),
    ];
    final tone =
        tones[title.codeUnits.fold<int>(0, (a, b) => a + b) % tones.length];
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone, Color.lerp(tone, palette.background, .62)!],
        ),
      ),
      child: Center(
        child: Icon(
          mediaType == 'audiobook'
              ? Icons.headphones_outlined
              : Icons.auto_stories_outlined,
          color: Colors.white.withValues(alpha: .55),
          size: width * .45,
        ),
      ),
    );
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: localPath != null
            ? Image.file(
                File(localPath!),
                fit: BoxFit.cover,
                cacheWidth: (width * 2).round(),
                errorBuilder: (_, _, _) => fallback,
              )
            : usable
            ? Image.network(
                cover!,
                fit: BoxFit.cover,
                cacheWidth: (width * 2).round(),
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}

class ObsidianLibraryPage extends StatefulWidget {
  final LibraryService service;
  final ShelfNavigation navigation;
  final VoidCallback onSettings;
  const ObsidianLibraryPage({
    super.key,
    required this.service,
    required this.navigation,
    required this.onSettings,
  });
  @override
  State<ObsidianLibraryPage> createState() => _ObsidianLibraryPageState();
}

class _ObsidianLibraryPageState extends State<ObsidianLibraryPage> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  Timer? _searchTimer;
  String _searchQuery = '';
  static final _spaces = RegExp(r'\s+');
  String type = 'all', scope = 'all', year = 'all', sort = 'completed';
  String? selectedId;
  bool filters = false, grid = false;
  bool selecting = false,
      favoritesOnly = false,
      descending = true,
      hiddenOnly = false;
  String statusFilter = 'all', collectionFilter = 'all';
  final selectedBooks = <String>{};
  List<LibraryEntry>? _filterInput;
  Object? _filterKey;
  List<LibraryEntry> _filtered = [];
  int? annualGoal;
  String? goalNamespace;
  @override
  void initState() {
    super.initState();
    unawaited(_loadGoal());
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  String get _goalKey => 'library-year-goal:personal:${DateTime.now().year}';
  Future<void> _loadGoal() async {
    final namespace = widget.service.config?.namespace;
    final raw =
        await widget.service.local.meta(_goalKey) ??
        await widget.service.local.meta(
          'library-year-goal:${namespace ?? 'unconnected'}:${DateTime.now().year}',
        );
    if (mounted && namespace == widget.service.config?.namespace) {
      if (raw != null) await widget.service.local.setMeta(_goalKey, raw);
      if (!mounted) return;
      setState(() {
        goalNamespace = namespace;
        annualGoal = int.tryParse(raw ?? '');
      });
    }
  }

  Future<void> _setGoal() async {
    final controller = TextEditingController(
      text: annualGoal?.toString() ?? '',
    );
    final next = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Цель на ${DateTime.now().year}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Книг и аудиокниг за год',
            helperText: 'Завершённые записи с датой окончания в этом году',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text);
              if (n != null && n > 0 && n <= 10000) Navigator.pop(context, n);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    // The route's exit animation can still reference its controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (next == null || !mounted) return;
    await widget.service.local.setMeta(_goalKey, '$next');
    if (mounted) setState(() => annualGoal = next);
  }

  Future<void> _exchange() => Navigator.push<void>(
    context,
    MaterialPageRoute(builder: (_) => LibraryDataPage(library: widget.service)),
  );
  Future<void> _add() async {
    final audio = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Добавить произведение'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Книга'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Аудиокнига'),
          ),
        ],
      ),
    );
    if (audio == null || !mounted) return;
    final draft = widget.service.emptyDraft(audio: audio);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          item: draft,
          collection: widget.service.collectionFor(draft),
          suggestions: widget.service.suggestions,
          onPickCover: widget.service.chooseCover,
          onSearchCover: () => Navigator.push<String>(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  LibraryCoverSearch(library: widget.service, item: draft),
            ),
          ),
          coverResolver: widget.service.coverReferencePath,
          saveLabel: 'Добавить в библиотеку',
          onSave: (values) => widget.service.add(draft.withValues(values), ''),
        ),
      ),
    );
  }

  Future<void> _open(LibraryEntry entry) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          LibraryWorkPage(library: widget.service, itemId: entry.item.id),
    ),
  );
  Future<void> _edit(LibraryEntry entry) =>
      editLibraryEntry(context, widget.service, entry);
  Future<void> _groups(String kind) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => LibraryGroupsPage(library: widget.service, kind: kind),
    ),
  );
  bool _matches(LibraryEntry entry, List<String> terms) {
    final item = entry.item;
    final text = terms.isEmpty
        ? ''
        : switch (scope) {
            'title' => item.title,
            'author' => item.authors,
            'series' => _text(item.value('series')),
            _ => [
              item.title,
              item.authors,
              _text(item.value('series')),
              _text(item.value('genre')),
              _text(item.values['tags']),
            ].join(' '),
          };
    final haystack = text.toLowerCase().replaceAll('ё', 'е');
    return (type == 'all' || item.mediaType == type) &&
        (statusFilter == 'all' || libraryStatus(item) == statusFilter) &&
        (collectionFilter == 'all' ||
            libraryCollections(item).contains(collectionFilter)) &&
        ((item.values['pepehub_hidden'] == true) == hiddenOnly) &&
        (!favoritesOnly || item.values['pepehub_favorite'] == true) &&
        (year == 'all' ||
            (year == 'unknown'
                ? libraryCompletionDate(item) == null
                : '${libraryCompletionDate(item)?.year}' == year)) &&
        terms.every(haystack.contains);
  }

  int _compare(LibraryEntry a, LibraryEntry b) =>
      compareLibraryEntries(a, b, sort, descending: descending);

  List<LibraryEntry> _results(List<LibraryEntry> all) {
    final key = (
      _searchQuery,
      type,
      scope,
      year,
      sort,
      descending,
      hiddenOnly,
      favoritesOnly,
      statusFilter,
      collectionFilter,
    );
    if (!identical(all, _filterInput) || key != _filterKey) {
      _filterInput = all;
      _filterKey = key;
      final normalized = _searchQuery.trim().toLowerCase().replaceAll('ё', 'е');
      final terms = normalized.isEmpty ? <String>[] : normalized.split(_spaces);
      _filtered = all.where((entry) => _matches(entry, terms)).toList()
        ..sort(_compare);
    }
    return _filtered;
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
          searchFocus.requestFocus(),
    },
    child: ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final service = widget.service, palette = ShelfPalette.of(context);
        if (goalNamespace != service.config?.namespace) {
          goalNamespace = service.config?.namespace;
          annualGoal = null;
          unawaited(_loadGoal());
        }
        final all = service.visibleEntries;
        final entries = _results(all);
        final selected =
            entries.where((e) => e.item.id == selectedId).firstOrNull ??
            entries.firstOrNull;
        final books = service.completed
                .where((e) => e.item.mediaType == 'book')
                .length,
            audio = service.completed.length - books;
        return ShelfShell(
          title: 'Библиотека',
          navigation: widget.navigation,
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Действия библиотеки',
              onSelected: (action) async {
                if (!mounted) return;
                if (['author', 'series', 'collection'].contains(action)) {
                  await _groups(action);
                }
                if (!context.mounted) return;
                if (action == 'hidden') {
                  setState(() => hiddenOnly = !hiddenOnly);
                }
                if (action == 'notes') {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ObsidianNotesPage(library: service),
                    ),
                  );
                  return;
                }
                if (action == 'journal') {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ActivityPage(library: service),
                    ),
                  );
                }
                if (action == 'select') {
                  setState(() {
                    selecting = !selecting;
                    selectedBooks.clear();
                  });
                }
                if (action == 'favorites') {
                  setState(() => favoritesOnly = !favoritesOnly);
                }
                if (action == 'trash') {
                  if (!context.mounted) return;
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LibraryTrashPage(service: service),
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'notes',
                  child: Text('Цитаты и заметки'),
                ),
                const PopupMenuItem(value: 'author', child: Text('Авторы')),
                const PopupMenuItem(value: 'series', child: Text('Серии')),
                const PopupMenuItem(
                  value: 'collection',
                  child: Text('Коллекции'),
                ),
                PopupMenuItem(
                  value: 'hidden',
                  child: Text(
                    hiddenOnly ? 'Вернуться к видимым' : 'Скрытые карточки',
                  ),
                ),
                const PopupMenuItem(
                  value: 'journal',
                  child: Text('Журнал чтения и прослушивания'),
                ),
                PopupMenuItem(
                  value: 'select',
                  child: Text(
                    selecting ? 'Завершить выбор' : 'Выбрать несколько книг',
                  ),
                ),
                PopupMenuItem(
                  value: 'favorites',
                  child: Text(
                    favoritesOnly ? 'Показать все книги' : 'Только избранные',
                  ),
                ),
                PopupMenuItem(
                  value: 'trash',
                  child: Text('Корзина · ${service.trash.length}'),
                ),
              ],
            ),
            IconButton(
              tooltip: 'Экспорт и резервные копии',
              onPressed: _exchange,
              icon: const Icon(Icons.backup_outlined, size: 20),
            ),
          ],
          body: LayoutBuilder(
            builder: (context, constraints) {
              final details = constraints.maxWidth >= 1040;
              final list = CustomScrollView(
                key: const PageStorageKey('personal-library-list'),
                scrollCacheExtent: const ScrollCacheExtent.pixels(300),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Записей: ${all.length}',
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _add,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Добавить'),
                              ),
                            ],
                          ),
                          if (service.loading) ...[
                            const LinearProgressIndicator(minHeight: 2),
                            const SizedBox(height: 4),
                            Text(
                              'Обновляем сведения о файлах…',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                          if (service.error != null)
                            Text(
                              service.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ExpansionTile(
                            key: const PageStorageKey('library-summary'),
                            tilePadding: EdgeInsets.zero,
                            minTileHeight: 40,
                            dense: true,
                            title: Text(
                              'Итоги и цель · $books книг, $audio аудиокниг',
                              style: const TextStyle(fontSize: 12),
                            ),
                            children: [_goal(service.completed)],
                          ),
                          const SizedBox(height: 8),
                          if (selecting)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('Выбрано: ${selectedBooks.length}'),
                                  TextButton(
                                    onPressed: () => setState(() {
                                      selectedBooks.clear();
                                      selectedBooks.addAll(
                                        entries.map((e) => e.item.id),
                                      );
                                    }),
                                    child: const Text('Выбрать показанные'),
                                  ),
                                  PopupMenuButton<String>(
                                    tooltip: 'Массовые действия',
                                    enabled: selectedBooks.isNotEmpty,
                                    onSelected: (action) => libraryBatchAction(
                                      context,
                                      service,
                                      selectedBooks.toList(),
                                      action,
                                    ),
                                    itemBuilder: (_) => [
                                      for (final e
                                          in libraryBatchLabels.entries)
                                        PopupMenuItem(
                                          value: e.key,
                                          child: Text(e.value),
                                        ),
                                    ],
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Text('Действия с выбранными ▾'),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: selectedBooks.isEmpty
                                        ? null
                                        : () async {
                                            if (await deleteLibraryCards(
                                                  context,
                                                  service,
                                                  selectedBooks.toList(),
                                                ) &&
                                                mounted) {
                                              setState(() {
                                                selectedBooks.clear();
                                                selecting = false;
                                              });
                                            }
                                          },
                                    icon: const Icon(Icons.delete_outline),
                                    label: const Text('В корзину'),
                                  ),
                                  TextButton(
                                    onPressed: () => setState(() {
                                      selectedBooks.clear();
                                      selecting = false;
                                    }),
                                    child: const Text('Отмена'),
                                  ),
                                ],
                              ),
                            ),
                          if (favoritesOnly)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: InputChip(
                                label: const Text('Только избранные'),
                                onDeleted: () =>
                                    setState(() => favoritesOnly = false),
                              ),
                            ),
                          _collectionControls(all),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    sliver: _collectionSliver(entries, all, selected, details),
                  ),
                ],
              );
              if (!details) return list;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: list),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 300,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(right: 20, bottom: 24),
                      child: selected != null
                          ? _detail(selected)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ),
  );
  Widget _collectionControls(List<LibraryEntry> all) {
    final palette = ShelfPalette.of(context);
    final pill = OutlineInputBorder(
      borderRadius: BorderRadius.circular(26),
      borderSide: BorderSide(color: palette.line),
    );
    final field = TextField(
      key: const ValueKey('library-search'),
      controller: search,
      focusNode: searchFocus,
      onChanged: (_) {
        _searchTimer?.cancel();
        _searchTimer = Timer(const Duration(milliseconds: 200), () {
          if (mounted) setState(() => _searchQuery = search.text);
        });
      },
      decoration: InputDecoration(
        hintText: 'Название, автор или серия…',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (search.text.isNotEmpty)
              IconButton(
                tooltip: 'Очистить поиск',
                onPressed: () {
                  _searchTimer?.cancel();
                  setState(() {
                    search.clear();
                    _searchQuery = '';
                  });
                },
                icon: const Icon(Icons.close, size: 17),
              ),
            IconButton(
              tooltip: filters ? 'Скрыть фильтры' : 'Фильтры библиотеки',
              onPressed: () => setState(() => filters = !filters),
              icon: Icon(filters ? Icons.close : Icons.tune_rounded, size: 20),
            ),
          ],
        ),
        isDense: true,
        border: pill,
        enabledBorder: pill,
      ),
    );
    final selector = DropdownButtonFormField<String>(
      key: ValueKey('library-search-scope:$scope'),
      initialValue: scope,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        border: pill,
        enabledBorder: pill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 13,
        ),
      ),
      items: const [
        DropdownMenuItem(value: 'all', child: Text('Везде')),
        DropdownMenuItem(value: 'title', child: Text('В названии')),
        DropdownMenuItem(value: 'author', child: Text('По автору')),
        DropdownMenuItem(value: 'series', child: Text('По серии')),
      ],
      onChanged: (next) => setState(() => scope = next ?? 'all'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 520
              ? Column(
                  children: [
                    field,
                    if (filters) ...[const SizedBox(height: 10), selector],
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: field),
                    if (filters) ...[
                      const SizedBox(width: 10),
                      SizedBox(width: 160, child: selector),
                    ],
                  ],
                ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final option in const {
              'all': 'Все',
              'book': 'Книги',
              'audiobook': 'Аудиокниги',
            }.entries)
              ChoiceChip(
                label: Text(option.value),
                selected: type == option.key,
                showCheckmark: false,
                onSelected: (_) => setState(() => type = option.key),
              ),
          ],
        ),
        if (!filters)
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              label: Text(
                statusFilter == 'all'
                    ? 'Все статусы'
                    : libraryStatusesLocal[statusFilter] ?? statusFilter,
              ),
              avatar: const Icon(Icons.filter_list, size: 16),
              onPressed: () => setState(() => filters = true),
            ),
          ),
        if (filters) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('library-status:$statusFilter'),
            initialValue: statusFilter,
            decoration: const InputDecoration(
              labelText: 'Статус книги',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('Все статусы')),
              for (final e in libraryStatusesLocal.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => statusFilter = v ?? 'all'),
          ),
        ],
        if (filters) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('library-collection:$collectionFilter'),
            initialValue: collectionFilter,
            decoration: const InputDecoration(
              labelText: 'Коллекция',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(
                value: 'all',
                child: Text('Все коллекции'),
              ),
              for (final name in ({
                ...all.expand((e) => libraryCollections(e.item)),
                if (collectionFilter != 'all') collectionFilter,
              }.toList()..sort()))
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: (v) => setState(() => collectionFilter = v ?? 'all'),
          ),
        ],
        if (filters)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: DropdownButtonFormField<String>(
              key: ValueKey('library-year:$year'),
              initialValue: year,
              decoration: const InputDecoration(
                labelText: 'Год завершения',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('Все годы')),
                const DropdownMenuItem(
                  value: 'unknown',
                  child: Text('Дата не указана'),
                ),
                for (final value in ({
                  ...all
                      .map((e) => libraryCompletionDate(e.item)?.year)
                      .whereType<int>(),
                  if (int.tryParse(year) != null) int.parse(year),
                }.toList()..sort((a, b) => b.compareTo(a))))
                  DropdownMenuItem(value: '$value', child: Text('$value')),
              ],
              onChanged: (next) => setState(() => year = next ?? 'all'),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                value: sort,
                isExpanded: true,
                underline: const SizedBox(),
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: palette.text,
                  fontSize: 13,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'added',
                    child: Text('Недавно добавленные'),
                  ),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text('По дате завершения'),
                  ),
                  DropdownMenuItem(
                    value: 'recent',
                    child: Text('Недавно изменённые'),
                  ),
                  DropdownMenuItem(
                    value: 'title',
                    child: Text('По названию А–Я'),
                  ),
                  DropdownMenuItem(
                    value: 'author',
                    child: Text('По автору А–Я'),
                  ),
                  DropdownMenuItem(
                    value: 'series',
                    child: Text('По серии А–Я'),
                  ),
                  DropdownMenuItem(
                    value: 'progress',
                    child: Text('По прогрессу'),
                  ),
                  DropdownMenuItem(value: 'rating', child: Text('По оценке')),
                ],
                onChanged: (next) => setState(() {
                  sort = next ?? 'added';
                  if (sort == 'added') statusFilter = 'all';
                  descending = [
                    'added',
                    'completed',
                    'recent',
                    'rating',
                    'progress',
                  ].contains(sort);
                }),
              ),
            ),
            IconButton(
              tooltip: descending ? 'По убыванию' : 'По возрастанию',
              onPressed: () => setState(() => descending = !descending),
              icon: Icon(descending ? Icons.south : Icons.north, size: 20),
            ),
            IconButton(
              tooltip: grid ? 'Показать списком' : 'Показать карточками',
              onPressed: () => setState(() => grid = !grid),
              icon: Icon(
                grid ? Icons.view_list_outlined : Icons.grid_view_rounded,
                size: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _collectionSliver(
    List<LibraryEntry> entries,
    List<LibraryEntry> all,
    LibraryEntry? selected,
    bool details,
  ) {
    if (entries.isEmpty) {
      return SliverToBoxAdapter(
        child: ShelfPanel(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            children: [
              Text(
                all.isEmpty
                    ? widget.service.loading
                          ? 'Загружаем библиотеку…'
                          : 'В библиотеке пока нет записей'
                    : 'Ничего не найдено',
              ),
              if (all.isEmpty && !widget.service.loading)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Добавьте завершённую, отложенную или брошенную книгу из вкладки файлов или кнопкой «Добавить».',
                    textAlign: TextAlign.center,
                  ),
                ),
              if (all.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    search.clear();
                    type = year = scope = statusFilter = collectionFilter =
                        'all';
                    hiddenOnly = favoritesOnly = false;
                  }),
                  child: const Text('Сбросить фильтры'),
                ),
            ],
          ),
        ),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.crossAxisExtent;
        if (grid) {
          const gap = 16.0;
          final columns = (available / 200).floor().clamp(2, 8);
          final width = (available - gap * (columns - 1)) / columns;
          return SliverGrid.builder(
            itemCount: entries.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
              mainAxisExtent:
                  width * 1.5 +
                  228 * MediaQuery.textScalerOf(context).scale(1) -
                  64,
            ),
            itemBuilder: (_, i) => KeyedSubtree(
              key: ValueKey('library-work:${entries[i].item.id}'),
              child: _gridCard(
                entries[i],
                selected?.item.id == entries[i].item.id,
                details,
                width,
              ),
            ),
          );
        }
        final table = available >= 620;
        return SliverList.builder(
          itemCount: entries.length + (table ? 1 : 0),
          itemBuilder: (_, index) {
            if (table && index == 0) return _tableHeader();
            final entry = entries[index - (table ? 1 : 0)];
            return Material(
              key: ValueKey('library-work:${entry.item.id}'),
              color: ShelfPalette.of(context).panel,
              child: _row(
                entry,
                selected?.item.id == entry.item.id,
                details,
                table,
              ),
            );
          },
        );
      },
    );
  }

  Widget _tableHeader() {
    final muted = ShelfPalette.of(context).muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Название',
              style: TextStyle(color: muted, fontSize: 10),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text('Тип', style: TextStyle(color: muted, fontSize: 10)),
          ),
          SizedBox(
            width: 102,
            child: Text('Статус', style: TextStyle(color: muted, fontSize: 10)),
          ),
          SizedBox(
            width: 122,
            child: Text(
              'Прогресс',
              style: TextStyle(color: muted, fontSize: 10),
            ),
          ),
          SizedBox(
            width: 50,
            child: Text('Оценка', style: TextStyle(color: muted, fontSize: 10)),
          ),
          const SizedBox(width: 32),
        ],
      ),
    );
  }

  void _select(LibraryEntry entry, bool details) {
    if (selecting) {
      setState(() {
        if (!selectedBooks.add(entry.item.id)) {
          selectedBooks.remove(entry.item.id);
        }
      });
      return;
    }
    setState(() => selectedId = entry.item.id);
    if (!details) unawaited(_open(entry));
  }

  Widget _status(LibraryEntry entry) {
    if (entry.state != 'synced') {
      return Text(
        libraryState(entry),
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
    final status = metadataReadingStatus(entry.item);
    return status == 'other'
        ? Text(
            _text(entry.item.value('status')).isEmpty
                ? 'Без статуса'
                : _text(entry.item.value('status')),
            style: TextStyle(
              fontSize: 10,
              color: ShelfPalette.of(context).muted,
            ),
          )
        : ShelfStatus(status);
  }

  Widget _progress(LibraryEntry entry) {
    final fraction = metadataProgress(entry.item),
        palette = ShelfPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fraction == null ? '—' : '${(fraction * 100).round()}%',
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction ?? 0,
            minHeight: 3,
            color: metadataReadingStatus(entry.item) == 'finished'
                ? palette.muted
                : palette.accent,
            backgroundColor: palette.line,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          metadataProgressLabel(entry.item),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.muted, fontSize: 9),
        ),
      ],
    );
  }

  Widget _rating(ObsidianLibraryItem item) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_text(item.value('rating')).isNotEmpty)
        const Icon(Icons.star_rounded, color: Color(0xffc9ae78), size: 12),
      Flexible(
        child: Text(
          _text(item.value('rating')).isEmpty
              ? '—'
              : _text(item.value('rating')),
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ],
  );
  Widget _menu(LibraryEntry entry) => PopupMenuButton<String>(
    tooltip: 'Действия с книгой',
    icon: const Icon(Icons.more_horiz, size: 20),
    onSelected: (action) async {
      try {
        if (action == 'edit') await _edit(entry);
        if (action == 'status' && mounted) {
          await libraryBatchAction(context, widget.service, [
            entry.item.id,
          ], 'status');
        }
        if (action == 'collection' && mounted) {
          await libraryBatchAction(context, widget.service, [
            entry.item.id,
          ], 'collection');
        }
        if (action == 'time' && mounted) {
          await editLibraryAudioTime(context, widget.service, entry);
        }
        if (action == 'favorite') await widget.service.favorite(entry.item.id);
        if (action == 'delete' && mounted) {
          await deleteLibraryCards(context, widget.service, [entry.item.id]);
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'edit', child: Text('Редактировать карточку')),
      const PopupMenuItem(value: 'status', child: Text('Изменить статус')),
      const PopupMenuItem(
        value: 'collection',
        child: Text('Добавить в коллекцию'),
      ),
      if (entry.item.mediaType == 'audiobook' &&
          ['', 'minutes', 'hours'].contains(entry.item.value('unit') ?? ''))
        const PopupMenuItem(value: 'time', child: Text('Время прослушивания…')),
      PopupMenuItem(
        value: 'favorite',
        child: Text(
          entry.item.values['pepehub_favorite'] == true
              ? 'Убрать из избранного'
              : 'В избранное',
        ),
      ),
      const PopupMenuItem(value: 'delete', child: Text('В корзину')),
    ],
  );

  Widget _row(LibraryEntry entry, bool selected, bool details, bool table) {
    final item = entry.item, palette = ShelfPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: selected && details
            ? palette.selected.withValues(alpha: .65)
            : null,
        border: Border(
          bottom: BorderSide(color: palette.line),
          left: BorderSide(
            color: selected && details ? palette.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: InkWell(
        onTap: () => _select(entry, details),
        onLongPress: () => setState(() {
          selecting = true;
          selectedBooks.add(entry.item.id);
        }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 14, 12, 14),
          child: Row(
            children: [
              ShelfBookCover(
                title: item.title,
                mediaType: item.mediaType,
                cover: _text(item.value('cover')),
                localPath: widget.service.coverPath(item),
                width: 36,
                height: 54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(palette.text, size: 15),
                    ),
                    if (item.authors.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        item.authors,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: palette.muted),
                      ),
                    ],
                    if (_text(item.value('series')).isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'Серия: ${_text(item.value('series'))}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9, color: palette.accent),
                      ),
                    ],
                    if (!table) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _status(entry),
                          Text(
                            metadataProgressLabel(item),
                            style: TextStyle(
                              fontSize: 10,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (table) ...[
                SizedBox(
                  width: 46,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Tooltip(
                      message: item.mediaType == 'audiobook'
                          ? 'Аудиокнига'
                          : 'Книга',
                      child: Icon(
                        item.mediaType == 'audiobook'
                            ? Icons.headphones_outlined
                            : Icons.auto_stories_outlined,
                        size: 15,
                        color: palette.muted,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 102,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _status(entry),
                  ),
                ),
                SizedBox(
                  width: 122,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: _progress(entry),
                  ),
                ),
                SizedBox(width: 50, child: _rating(item)),
              ],
              SizedBox(
                width: 32,
                child: selecting
                    ? Checkbox(
                        value: selectedBooks.contains(item.id),
                        onChanged: (_) => _select(entry, details),
                      )
                    : _menu(entry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gridCard(
    LibraryEntry entry,
    bool selected,
    bool details,
    double width,
  ) {
    final item = entry.item, palette = ShelfPalette.of(context);
    final rating = _number(item.value('rating'));
    return Material(
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected && details ? palette.accent : Colors.transparent,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _select(entry, details),
        onLongPress: () => setState(() {
          selecting = true;
          selectedBooks.add(entry.item.id);
        }),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                ShelfBookCover(
                  title: item.title,
                  mediaType: item.mediaType,
                  cover: _text(item.value('cover')),
                  localPath: widget.service.coverPath(item),
                  width: width,
                  height: width * 1.5,
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.background.withValues(alpha: .85),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      item.mediaType == 'audiobook' ? 'АУДИО' : 'КНИГА',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .8,
                        color: palette.text,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: Material(
                    color: palette.panel.withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(24),
                    child: selecting
                        ? Checkbox(
                            value: selectedBooks.contains(item.id),
                            onChanged: (_) => _select(entry, details),
                          )
                        : _menu(entry),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(palette.text, size: 15),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.authors,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Flexible(child: _status(entry)),
                        if (item.values['pepehub_favorite'] == true)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.favorite,
                              size: 14,
                              color: palette.accent,
                            ),
                          ),
                        if (rating != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '★ ${_amount(rating)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.accent,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      metadataProgressLabel(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(LibraryEntry entry) {
    final item = entry.item, palette = ShelfPalette.of(context);
    Widget value(String label, dynamic value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: palette.muted)),
        const SizedBox(height: 7),
        Text(
          _text(value).isEmpty ? 'Не указана' : _text(value),
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
    return ShelfPanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Карточка книги',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Все метаданные',
                onPressed: () => _edit(entry),
                icon: Icon(Icons.edit_outlined, color: palette.muted, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShelfBookCover(
                title: item.title,
                mediaType: item.mediaType,
                cover: _text(item.value('cover')),
                localPath: widget.service.coverPath(item),
                width: 62,
                height: 93,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга',
                      style: TextStyle(fontSize: 10, color: palette.muted),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(palette.text, size: 20),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.authors,
                      style: TextStyle(fontSize: 11, color: palette.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _status(entry),
          const SizedBox(height: 14),
          _progress(entry),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: value('Дата начала', item.value('startDate'))),
              const SizedBox(width: 10),
              Expanded(child: value('Дата завершения', item.value('endDate'))),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: value('Формат', item.value('format'))),
              const SizedBox(width: 10),
              Expanded(child: value('Ваша оценка', item.value('rating'))),
            ],
          ),
          const SizedBox(height: 18),
          if (_text(item.value('genre')).isNotEmpty) ...[
            value('Жанры', item.value('genre')),
            const SizedBox(height: 18),
          ],
          FilledButton.icon(
            onPressed: () => _open(entry),
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('Открыть карточку произведения'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ActivityPage(library: widget.service, itemId: item.id),
              ),
            ),
            icon: const Icon(Icons.history, size: 16),
            label: const Text('Журнал этой книги'),
          ),
          const SizedBox(height: 13),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.local_library_outlined,
                size: 12,
                color: palette.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  libraryState(entry),
                  style: TextStyle(fontSize: 10, color: palette.muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _goal(List<LibraryEntry> entries) {
    final palette = ShelfPalette.of(context), year = DateTime.now().year;
    final finished = entries.where((entry) {
      if (metadataReadingStatus(entry.item) != 'finished') return false;
      final raw = _text(entry.item.value('endDate'));
      final iso = DateTime.tryParse(raw);
      if (iso != null) return iso.year == year;
      final parts = raw.split('.');
      return parts.length == 3 && int.tryParse(parts.last) == year;
    }).length;
    final goal = annualGoal;
    if (goal == null) {
      return ShelfPanel(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$year · завершено $finished',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(onPressed: _setGoal, child: const Text('Задать цель')),
          ],
        ),
      );
    }
    final ticks = goal.clamp(1, 60);
    final done = (finished * ticks / goal).floor().clamp(0, ticks);
    return ShelfPanel(
      padding: const EdgeInsets.fromLTRB(20, 16, 10, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Цель на $year',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: palette.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'книг и аудиокниг завершено',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
              ),
              Text.rich(
                TextSpan(
                  text: '$finished',
                  style: AppFonts.title(palette.text, size: 34),
                  children: [
                    TextSpan(
                      text: ' / $goal',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                children: [
                  for (var i = 0; i < ticks; i++)
                    Expanded(
                      child: Container(
                        height: 14,
                        margin: EdgeInsets.only(right: i == ticks - 1 ? 0 : 3),
                        decoration: BoxDecoration(
                          color: i < done ? palette.accent : palette.raised,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          TextButton(
            onPressed: _setGoal,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: const Text('Изменить цель'),
          ),
        ],
      ),
    );
  }
}
