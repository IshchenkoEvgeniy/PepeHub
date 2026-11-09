import 'catalog_search.dart';

import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/reading_insights.dart';
import 'library_data_page.dart';
import 'library_work_page.dart';
import 'library_cover_search.dart';
import 'library_groups_page.dart';
import 'library_series_editor_page.dart';
import 'library_batch_actions.dart';
import '../library/library_features.dart';
import 'library_notes_page.dart';
import 'library_card_actions.dart';
import 'library_trash_page.dart';
import 'library_audio_time_sheet.dart';
import 'activity_page.dart';
import 'app_theme.dart';
import 'library_metadata_editor.dart' show LibraryMetadataEditor, libraryState;
import 'shelf_components.dart';
import '../diagnostics/user_message.dart';

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

String metadataReadingStatus(LibraryItem item) {
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

double? metadataProgress(LibraryItem item) {
  if (isUnreadSeriesItem(item)) return 0;
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
    // Seconds only matter for short spans: «2 ч 30 мин», «4 мин 10 с».
    if (seconds > 0 && hours == 0) '$seconds с',
    if (total == 0) '0 мин',
  ].join(' ');
}

String metadataProgressLabel(LibraryItem item) {
  if (isUnreadSeriesItem(item)) return 'Ещё не начата';
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
        : _duration(progress * factor) == _duration(total * factor)
        ? _duration(total * factor)
        : '${_duration(progress * factor)} / ${_duration(total * factor)}';
  }
  final label = unit.isEmpty || unit == 'pages' ? 'стр.' : unit;
  return progress == null
      ? '${_amount(total)} $label'
      : total == null
      ? '${_amount(progress)} $label'
      : '${_amount(progress)} / ${_amount(total)} $label';
}

String metadataSeriesListeningLabel(LibrarySeriesGroup group) =>
    'Прослушано: ${_duration(group.listenedMinutes)}';

/// «9 аудиокниг», «2 книги · 3 аудиокниги»: types with zero items are skipped.
String metadataSeriesCountLabel(int books, int audiobooks) {
  String count(int n, String one, String few, String many) {
    final last = n % 10, lastTwo = n % 100;
    return '$n ${last == 1 && lastTwo != 11
        ? one
        : last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)
        ? few
        : many}';
  }

  return [
    if (books > 0 || audiobooks == 0) count(books, 'книга', 'книги', 'книг'),
    if (audiobooks > 0)
      count(audiobooks, 'аудиокнига', 'аудиокниги', 'аудиокниг'),
  ].join(' · ');
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

/// Human label for the stored `format` field.
String libraryFormatName(Object? value) {
  final text = '${value ?? ''}'.trim();
  return switch (text.toLowerCase()) {
    '' => '',
    'audiobook' || 'audio' => 'Аудиокнига',
    'e-book' || 'ebook' => 'Электронная книга',
    'paper' || 'paperback' || 'hardcover' => 'Бумажная книга',
    _ => text,
  };
}

class LibraryArchivePage extends StatefulWidget {
  final LibraryService service;
  final ShelfNavigation navigation;
  final VoidCallback onSettings;
  const LibraryArchivePage({
    super.key,
    required this.service,
    required this.navigation,
    required this.onSettings,
  });
  @override
  State<LibraryArchivePage> createState() => _LibraryArchivePageState();
}

class _LibraryArchivePageState extends State<LibraryArchivePage> {
  final search = TextEditingController();
  final searchFocus = FocusNode();
  Timer? _searchTimer;
  String _searchQuery = '';
  String type = 'all', scope = 'all', year = 'all', sort = 'completed';
  String? selectedId;
  bool filters = false, grid = false;
  bool groupSeries = true;
  int _groupPreferenceEdit = 0;
  final expandedSeries = <String>{};
  List<LibrarySeriesGroup> _seriesGroups = [];
  bool selecting = false,
      favoritesOnly = false,
      descending = true,
      hiddenOnly = false;
  String statusFilter = 'all', collectionFilter = 'all';
  String ratingFilter = 'all';
  static const _viewKey = 'library-view-v1';
  static const _sortLabels = {
    'added': 'Недавно добавленные',
    'completed': 'По дате завершения',
    'started': 'По дате начала',
    'recent': 'Недавно изменённые',
    'title': 'По названию А–Я',
    'author': 'По автору А–Я',
    'series': 'По серии А–Я',
    'progress': 'По прогрессу',
    'rating': 'По оценке',
  };
  int _viewPreferenceEdit = 0;
  Future<void> _viewWrites = Future.value();
  final selectedBooks = <String>{};
  List<LibraryEntry>? _catalogInput;
  Object? _catalogKey;
  List<LibraryEntry> _catalogEntries = [];
  List<String> _collectionOptions = [];
  List<int> _yearOptions = [];
  Map<String, Set<int>> _completionYears = {};
  Map<String, int> _statusCounts = {};
  int _yearBooks = 0, _yearAudio = 0, _allBooks = 0, _allAudio = 0;
  List<LibraryEntry>? _filterInput;
  Object? _filterKey;
  List<LibraryEntry> _filtered = [];
  int? annualGoal;
  @override
  void initState() {
    super.initState();
    unawaited(_loadGoal());
    unawaited(_loadGrouping());
    unawaited(_loadView());
  }

  Future<void> _loadView() async {
    final edit = _viewPreferenceEdit;
    final raw = await widget.service.local.meta(_viewKey);
    if (!mounted || edit != _viewPreferenceEdit || raw == null) return;
    try {
      final saved = jsonDecode(raw);
      if (saved is! Map) return;
      setState(() {
        if (saved['grid'] is bool) grid = saved['grid'];
        if (saved['descending'] is bool) descending = saved['descending'];
        if (_sortLabels.containsKey(saved['sort'])) sort = saved['sort'];
        if (['all', 'book', 'audiobook'].contains(saved['type'])) {
          type = saved['type'];
        }
      });
    } on FormatException {
      // A damaged preference must not prevent the catalog from opening.
    }
  }

  void _changeView(VoidCallback change) {
    _viewPreferenceEdit++;
    setState(change);
    final value = jsonEncode({
      'grid': grid,
      'sort': sort,
      'descending': descending,
      'type': type,
    });
    _viewWrites = _viewWrites
        .then((_) => widget.service.local.setMeta(_viewKey, value))
        .catchError((Object _) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Не удалось запомнить вид библиотеки'),
              ),
            );
          }
        });
  }

  void _resetFilters() => _changeView(() {
    _searchTimer?.cancel();
    search.clear();
    _searchQuery = '';
    type = scope = year = statusFilter = collectionFilter = ratingFilter =
        'all';
    hiddenOnly = favoritesOnly = false;
  });

  Future<void> _loadGrouping() async {
    final edit = _groupPreferenceEdit;
    final value = await widget.service.local.meta('library-group-series-v1');
    if (mounted && edit == _groupPreferenceEdit) {
      setState(() => groupSeries = value != '0');
    }
  }

  Future<void> _toggleGrouping(bool value) async {
    _groupPreferenceEdit++;
    setState(() {
      groupSeries = value;
      if (!value && statusFilter == 'unread') statusFilter = 'all';
    });
    await widget.service.local.setMeta(
      'library-group-series-v1',
      value ? '1' : '0',
    );
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
    final raw =
        await widget.service.local.meta(_goalKey) ??
        await widget.service.local.meta(
          'library-year-goal:unconnected:${DateTime.now().year}',
        );
    if (!mounted) return;
    if (raw != null) await widget.service.local.setMeta(_goalKey, raw);
    if (mounted) setState(() => annualGoal = int.tryParse(raw ?? ''));
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
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Добавить произведение'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'book'),
            child: const Text('Книга'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'audiobook'),
            child: const Text('Аудиокнига'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'series'),
            child: const Text('Серия'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'series') {
      await openLibrarySeriesEditor(context, widget.service);
      return;
    }
    final draft = widget.service.emptyDraft(audio: choice == 'audiobook');
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          item: draft,
          collection: widget.service.collectionFor(draft),
          suggestions: widget.service.suggestions,
          seriesEntries: widget.service.seriesEntries,
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
            'narrator' => _text(item.values['narrator']),
            'series' => _text(item.value('series')),
            _ => [
              item.title,
              item.authors,
              _text(item.values['narrator']),
              _text(item.value('series')),
              _text(item.value('genre')),
              _text(item.values['tags']),
            ].join(' '),
          };
    final haystack = normalizeCatalogSearch(text);
    return (type == 'all' || item.mediaType == type) &&
        (collectionFilter == 'all' ||
            libraryCollections(item).contains(collectionFilter)) &&
        (!favoritesOnly || item.values['pepehub_favorite'] == true) &&
        (ratingFilter == 'all' ||
            (ratingFilter == 'unrated'
                ? libraryRating(item) == null
                : (libraryRating(item) ?? -1) >= int.parse(ratingFilter))) &&
        (year == 'all' ||
            (year == 'unknown'
                ? (_completionYears[item.id]?.isEmpty ?? true)
                : _completionYears[item.id]?.contains(int.tryParse(year)) ==
                      true)) &&
        terms.every(haystack.contains);
  }

  int _compare(LibraryEntry a, LibraryEntry b) =>
      compareLibraryEntries(a, b, sort, descending: descending);

  List<LibraryEntry> _results(List<LibraryEntry> all) {
    final currentYear = DateTime.now().year;
    final catalogKey = (hiddenOnly, groupSeries, currentYear);
    if (!identical(all, _catalogInput) || catalogKey != _catalogKey) {
      _catalogInput = all;
      _catalogKey = catalogKey;
      _catalogEntries = [];
      _completionYears = {};
      final collections = <String>{}, years = <int>{};
      _yearBooks = _yearAudio = _allBooks = _allAudio = 0;
      final completions = annualCompletionCounts(all, currentYear);
      _yearBooks = completions.reading;
      _yearAudio = completions.audio;
      for (final entry in all) {
        final item = entry.item;
        final hidden = item.values['pepehub_hidden'] == true;
        final completedYears = libraryCompletionDates(item)
            .map((d) => d.year)
            .toSet();
        _completionYears[item.id] = completedYears;
        if (!hidden && isFinishedLibraryItem(item)) {
          final audio = item.mediaType == 'audiobook';
          if (audio) {
            _allAudio++;
          } else {
            _allBooks++;
          }
        }
        if (hidden != hiddenOnly || !groupSeries && isUnreadSeriesItem(item)) {
          continue;
        }
        _catalogEntries.add(entry);
        collections.addAll(libraryCollections(item));
        years.addAll(completedYears);
      }
      _collectionOptions = collections.toList()..sort();
      _yearOptions = years.toList()..sort((a, b) => b.compareTo(a));
      _filterInput = null;
    }
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
      ratingFilter,
    );
    if (!identical(all, _filterInput) || key != _filterKey) {
      _filterInput = all;
      _filterKey = key;
      final terms = catalogSearchTerms(_searchQuery);
      final matched = _catalogEntries
          .where((entry) => _matches(entry, terms))
          .toList();
      _statusCounts = {};
      for (final entry in matched) {
        final status = libraryStatus(entry.item);
        _statusCounts[status] = (_statusCounts[status] ?? 0) + 1;
      }
      _filtered =
          matched
              .where(
                (entry) =>
                    statusFilter == 'all' ||
                    libraryStatus(entry.item) == statusFilter,
              )
              .toList()
            ..sort(_compare);
      _seriesGroups = groupLibrarySeries(_filtered);
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
        final entries = _results(service.seriesEntries);
        final all = _catalogEntries;
        final candidates = groupSeries
            ? _seriesGroups.expand((g) => g.entries)
            : entries;
        final selected =
            candidates.where((e) => e.item.id == selectedId).firstOrNull ??
            candidates.firstOrNull;
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
                if (action == 'notes') {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LibraryNotesPage(library: service),
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
                const PopupMenuItem(
                  value: 'journal',
                  child: Text('Журнал чтения и прослушивания'),
                ),
                PopupMenuItem(
                  value: 'trash',
                  child: Text('Скрытые и недоступные · корзина'),
                ),
              ],
            ),
            // Background folder checks fail silently otherwise: show it here.
            ListenableBuilder(
              listenable: service.folderStorage,
              builder: (context, _) {
                final folder = service.folderStorage;
                final failed = folder.enabled && folder.error != null;
                final waiting = folder.enabled && folder.pending != null;
                return IconButton(
                  key: const ValueKey('library-data-action'),
                  tooltip: failed
                      ? 'Папка библиотеки не обновляется — открыть'
                      : waiting
                      ? 'Папка библиотеки ждёт файлы с другого устройства'
                      : 'Экспорт и резервные копии',
                  onPressed: _exchange,
                  icon: Icon(
                    failed
                        ? Icons.sync_problem
                        : waiting
                        ? Icons.sync
                        : Icons.backup_outlined,
                    size: 20,
                    color: failed
                        ? Theme.of(context).colorScheme.error
                        : waiting
                        ? Colors.amber
                        : null,
                  ),
                );
              },
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
                                  'Показано ${entries.length} из ${all.length}',
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: selecting
                                    ? 'Завершить выбор'
                                    : 'Выбрать несколько книг',
                                isSelected: selecting,
                                onPressed: () => setState(() {
                                  selecting = !selecting;
                                  selectedBooks.clear();
                                }),
                                icon: const Icon(
                                  Icons.checklist_rounded,
                                  size: 20,
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
                              '${DateTime.now().year} · книг: $_yearBooks · аудиокниг: $_yearAudio',
                              style: const TextStyle(fontSize: 12),
                            ),
                            children: [
                              _goal(),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'За всё время · книг: $_allBooks · аудиокниг: $_allAudio',
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
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
                                        candidates.map((e) => e.item.id),
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
                                                  allowFileDeletion: false,
                                                ) &&
                                                mounted) {
                                              setState(() {
                                                selectedBooks.clear();
                                                selecting = false;
                                              });
                                            }
                                          },
                                    icon: const Icon(Icons.delete_outline),
                                    label: const Text('Удалить…'),
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
                          _collectionControls(),
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
  Widget _collectionControls() {
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
        DropdownMenuItem(value: 'narrator', child: Text('По чтецу')),
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
                onSelected: (_) => _changeView(() => type = option.key),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                key: const ValueKey('library-quick-status:all'),
                label: const Text('Все статусы'),
                showCheckmark: false,
                selected: statusFilter == 'all',
                onSelected: (_) => setState(() => statusFilter = 'all'),
              ),
              for (final entry in {
                'finished': 'Завершено',
                'paused': 'Отложено',
                'abandoned': 'Брошено',
                if (groupSeries)
                  'unread': type == 'audiobook'
                      ? 'Не прослушано'
                      : 'Не прочитано',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    key: ValueKey('library-quick-status:${entry.key}'),
                    label: Text(
                      '${entry.value} · ${_statusCounts[entry.key] ?? 0}',
                    ),
                    showCheckmark: false,
                    selected: statusFilter == entry.key,
                    onSelected: (selected) => setState(
                      () => statusFilter = selected ? entry.key : 'all',
                    ),
                  ),
                ),
            ],
          ),
        ),
        _activeFilters(),
        if (filters) ...[
          const SizedBox(height: 12),
          _advancedFilters(),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                key: const ValueKey('library-favorites-filter'),
                label: const Text('Только избранные'),
                selected: favoritesOnly,
                onSelected: (value) => setState(() => favoritesOnly = value),
              ),
              FilterChip(
                key: const ValueKey('library-hidden-filter'),
                label: const Text('Скрытые карточки'),
                selected: hiddenOnly,
                onSelected: (value) => setState(() => hiddenOnly = value),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                key: const ValueKey('library-sort'),
                value: sort,
                isExpanded: true,
                underline: const SizedBox(),
                style: TextStyle(
                  fontFamily: AppFonts.body,
                  color: palette.text,
                  fontSize: 13,
                ),
                items: [
                  for (final entry in _sortLabels.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (next) => _changeView(() {
                  sort = next ?? 'added';
                  descending = [
                    'added',
                    'completed',
                    'started',
                    'recent',
                    'rating',
                    'progress',
                  ].contains(sort);
                }),
              ),
            ),
            IconButton(
              tooltip: descending ? 'По убыванию' : 'По возрастанию',
              onPressed: () => _changeView(() => descending = !descending),
              icon: Icon(descending ? Icons.south : Icons.north, size: 20),
            ),
            IconButton(
              key: const ValueKey('library-group-series'),
              tooltip: groupSeries
                  ? 'Показать книги отдельно'
                  : 'Группировать по сериям',
              isSelected: groupSeries,
              onPressed: () => _toggleGrouping(!groupSeries),
              icon: const Icon(Icons.library_books_outlined, size: 20),
              selectedIcon: const Icon(Icons.library_books_rounded, size: 20),
            ),
            IconButton(
              tooltip: grid ? 'Показать списком' : 'Показать карточками',
              onPressed: () => _changeView(() => grid = !grid),
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

  Widget _activeFilters() {
    final active = <({String key, String label, VoidCallback clear})>[
      if (_searchQuery.trim().isNotEmpty)
        (
          key: 'search',
          label: 'Поиск: ${_searchQuery.trim()}',
          clear: () => setState(() {
            _searchTimer?.cancel();
            search.clear();
            _searchQuery = '';
          }),
        ),
      if (scope != 'all')
        (
          key: 'scope',
          label:
              'Поиск: ${{'title': 'в названии', 'author': 'по автору', 'narrator': 'по чтецу', 'series': 'по серии'}[scope]}',
          clear: () => setState(() => scope = 'all'),
        ),
      if (type != 'all')
        (
          key: 'type',
          label: type == 'book' ? 'Книги' : 'Аудиокниги',
          clear: () => _changeView(() => type = 'all'),
        ),
      if (statusFilter != 'all')
        (
          key: 'status',
          label: seriesVolumeStatuses(type)[statusFilter] ?? statusFilter,
          clear: () => setState(() => statusFilter = 'all'),
        ),
      if (collectionFilter != 'all')
        (
          key: 'collection',
          label: 'Коллекция: $collectionFilter',
          clear: () => setState(() => collectionFilter = 'all'),
        ),
      if (year != 'all')
        (
          key: 'year',
          label: year == 'unknown' ? 'Дата не указана' : 'Год: $year',
          clear: () => setState(() => year = 'all'),
        ),
      if (ratingFilter != 'all')
        (
          key: 'rating',
          label: ratingFilter == 'unrated'
              ? 'Без оценки'
              : 'Оценка: от $ratingFilter',
          clear: () => setState(() => ratingFilter = 'all'),
        ),
      if (favoritesOnly)
        (
          key: 'favorites',
          label: 'Только избранные',
          clear: () => setState(() => favoritesOnly = false),
        ),
      if (hiddenOnly)
        (
          key: 'hidden',
          label: 'Скрытые карточки',
          clear: () => setState(() => hiddenOnly = false),
        ),
    ];
    if (active.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('library-active-filters'),
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final filter in active)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: InputChip(
                key: ValueKey('library-active-${filter.key}'),
                label: Text(filter.label, overflow: TextOverflow.ellipsis),
                deleteButtonTooltipMessage: 'Убрать фильтр',
                onDeleted: filter.clear,
              ),
            ),
          TextButton(
            key: const ValueKey('library-reset-filters'),
            onPressed: _resetFilters,
            child: const Text('Сбросить всё'),
          ),
        ],
      ),
    );
  }

  Widget _advancedFilters() {
    Widget field(
      String name,
      String label,
      String value,
      Map<String, String> options,
      ValueChanged<String> change,
    ) => DropdownButtonFormField<String>(
      key: ValueKey('library-$name:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: name == 'rating' ? 'Значение из карточки' : null,
        isDense: true,
      ),
      items: [
        for (final entry in options.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(entry.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (next) {
        if (next != null) setState(() => change(next));
      },
    );
    final fields = [
      field('status', 'Статус книги', statusFilter, {
        'all': 'Все статусы',
        ...groupSeries ? seriesVolumeStatuses(type) : libraryStatusesLocal,
      }, (value) => statusFilter = value),
      field('collection', 'Коллекция', collectionFilter, {
        'all': 'Все коллекции',
        for (final name in _collectionOptions) name: name,
        if (collectionFilter != 'all') collectionFilter: collectionFilter,
      }, (value) => collectionFilter = value),
      field('year', 'Год завершения', year, {
        'all': 'Все годы',
        'unknown': 'Дата не указана',
        for (final value in _yearOptions) '$value': '$value',
        if (int.tryParse(year) != null) year: year,
      }, (value) => year = value),
      field('rating', 'Оценка', ratingFilter, {
        'all': 'Любая оценка',
        'unrated': 'Без оценки',
        for (var value = 0; value <= 10; value++) '$value': 'От $value',
      }, (value) => ratingFilter = value),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 880
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in fields) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }

  Widget _collectionSliver(
    List<LibraryEntry> entries,
    List<LibraryEntry> all,
    LibraryEntry? selected,
    bool details,
  ) {
    if (entries.isEmpty && (!groupSeries || _seriesGroups.isEmpty)) {
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
                  onPressed: _resetFilters,
                  child: const Text('Сбросить фильтры'),
                ),
            ],
          ),
        ),
      );
    }
    final slots = <({LibraryEntry? entry, LibrarySeriesGroup? series})>[];
    if (groupSeries) {
      for (final group in _seriesGroups) {
        if (group.isSeries) {
          slots.add((entry: null, series: group));
          if (!expandedSeries.contains(group.key)) continue;
        }
        slots.addAll(group.entries.map((e) => (entry: e, series: null)));
      }
    } else {
      slots.addAll(entries.map((e) => (entry: e, series: null)));
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.crossAxisExtent;
        if (grid) {
          const gap = 16.0;
          final columns = (available / 200).floor().clamp(2, 8);
          final width = (available - gap * (columns - 1)) / columns;
          return SliverGrid.builder(
            itemCount: slots.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
              // Exactly the text below the cover: no empty band on cards.
              mainAxisExtent: width * 1.5 + _gridTextExtent(context),
            ),
            itemBuilder: (_, i) {
              final slot = slots[i];
              if (slot.series != null) {
                return _seriesCard(slot.series!, width: width);
              }
              final entry = slot.entry!;
              return KeyedSubtree(
                key: ValueKey('library-work:${entry.item.id}'),
                child: _gridCard(
                  entry,
                  selected?.item.id == entry.item.id,
                  details,
                  width,
                ),
              );
            },
          );
        }
        final table = available >= 620;
        return SliverList.builder(
          itemCount: slots.length + (table ? 1 : 0),
          itemBuilder: (_, index) {
            if (table && index == 0) return _tableHeader();
            final slot = slots[index - (table ? 1 : 0)];
            if (slot.series != null) return _seriesCard(slot.series!);
            final entry = slot.entry!;
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

  /// Height of a grid card below its cover: two title lines, the author or
  /// count line, the status row and the progress line, at the current text
  /// scale and fonts.
  double _gridTextExtent(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    double lines(TextStyle style, [int count = 1]) {
      final painter = TextPainter(
        text: TextSpan(
          text: List.filled(count, 'Ég').join('\n'),
          style: base.merge(style),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final title = lines(
      AppFonts.book(ShelfPalette.of(context).text, size: 15),
      2,
    );
    final meta = lines(const TextStyle(fontSize: 12));
    final small = lines(const TextStyle(fontSize: 11));
    // Padding 10 + 10, gaps 3 + 8 + 5, status chip = text + 10, slack 4.
    return 40 + title + meta + (small + 10) + small;
  }

  Widget _seriesCard(LibrarySeriesGroup group, {double? width}) {
    final palette = ShelfPalette.of(context);
    final expanded = expandedSeries.contains(group.key);
    final finished = group.entries
        .where((e) => isFinishedLibraryItem(e.item))
        .length;
    final audio = group.entries
        .where((e) => e.item.mediaType == 'audiobook')
        .length;
    final count = 'Книг: ${group.entries.length - audio} · Аудиокниг: $audio';
    final author = group.entries
        .map((e) => e.item.authors)
        .firstWhere((a) => a.isNotEmpty, orElse: () => '');
    void toggle() => setState(() {
      if (!expandedSeries.add(group.key)) expandedSeries.remove(group.key);
    });
    void selectGroup() => setState(() {
      selecting = true;
      final ids = group.entries.map((e) => e.item.id).toSet();
      if (selectedBooks.containsAll(ids)) {
        selectedBooks.removeAll(ids);
      } else {
        selectedBooks.addAll(ids);
      }
    });
    Widget cover(LibraryEntry entry, double w, double h) => ShelfBookCover(
      title: entry.item.title,
      mediaType: entry.item.mediaType,
      cover: _text(entry.item.value('cover')),
      localPath: widget.service.coverPath(entry.item),
      width: w,
      height: h,
    );
    final arrow = IconButton(
      tooltip: expanded ? 'Свернуть серию' : 'Развернуть серию',
      onPressed: toggle,
      icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
    );
    final heading = Text(
      group.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.book(palette.text, size: width == null ? 17 : 15),
    );
    final summary = Text(
      '$count\nЗавершено: $finished из ${group.entries.length}'
      '${audio > 0 ? '\n${metadataSeriesListeningLabel(group)}' : ''}',
      maxLines: width == null ? null : 5,
      overflow: width == null ? null : TextOverflow.ellipsis,
      style: TextStyle(color: palette.muted, fontSize: 12, height: 1.5),
    );
    return Semantics(
      key: ValueKey('library-series:${group.key}'),
      expanded: expanded,
      child: Material(
        color: palette.panel,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(width == null ? 8 : 16),
        child: InkWell(
          onTap: toggle,
          onLongPress: selectGroup,
          child: width == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      if (selecting)
                        Checkbox(
                          value: group.entries.every(
                            (e) => selectedBooks.contains(e.item.id),
                          ),
                          onChanged: (_) => selectGroup(),
                        ),
                      SizedBox(
                        width: 36 + (group.entries.length.clamp(1, 3) - 1) * 10,
                        height: 66,
                        child: Stack(
                          children: [
                            for (
                              var i = group.entries.length.clamp(1, 3) - 1;
                              i >= 0;
                              i--
                            )
                              Positioned(
                                left: i * 10,
                                top: i * 6,
                                child: cover(group.entries[i], 36, 54),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: 4),
                            summary,
                          ],
                        ),
                      ),
                      arrow,
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: width * 1.5,
                      child: Stack(
                        children: [
                          // The stack fills the cover area like a single
                          // book's cover; covers are cropped slightly.
                          for (
                            var i = group.entries.length.clamp(1, 3) - 1;
                            i >= 0;
                            i--
                          )
                            Positioned(
                              left: 12 + i * 12,
                              top: 12 + i * 12,
                              child: cover(
                                group.entries[i],
                                width -
                                    24 -
                                    (group.entries.length.clamp(1, 3) - 1) * 12,
                                width * 1.5 -
                                    20 -
                                    (group.entries.length.clamp(1, 3) - 1) * 12,
                              ),
                            ),
                          Positioned(
                            left: 8,
                            top: 8,
                            child: _typeBadge(
                              audio == 0
                                  ? 'КНИГИ'
                                  : audio == group.entries.length
                                  ? 'АУДИО'
                                  : 'КНИГИ + АУДИО',
                            ),
                          ),
                          if (selecting)
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Checkbox(
                                value: group.entries.every(
                                  (e) => selectedBooks.contains(e.item.id),
                                ),
                                onChanged: (_) => selectGroup(),
                              ),
                            ),
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: Material(
                              color: palette.panel,
                              borderRadius: BorderRadius.circular(24),
                              child: arrow,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: 3),
                            Text(
                              author.isEmpty ? 'Серия' : author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                              ),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Flexible(
                                  flex: 3,
                                  child: Text(
                                    'Завершено $finished из ${group.entries.length}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 2,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: group.entries.isEmpty
                                          ? 0
                                          : finished / group.entries.length,
                                      minHeight: 4,
                                      backgroundColor: palette.line,
                                      color: palette.accent,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            Text(
                              [
                                metadataSeriesCountLabel(
                                  group.entries.length - audio,
                                  audio,
                                ),
                                if (audio > 0) _duration(group.listenedMinutes),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
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
    if (isUnreadSeriesItem(entry.item)) {
      return Text(
        libraryItemStatuses(entry.item)['unread']!,
        style: TextStyle(fontSize: 11, color: ShelfPalette.of(context).muted),
      );
    }
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

  Widget _rating(LibraryItem item) {
    final known = libraryRating(item) != null;
    final label = libraryRatingLabel(item);
    final color = ShelfPalette.of(context).accent;
    return Semantics(
      label: known ? 'Оценка: ${label.substring(2)}' : 'Без оценки',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (known) ...[
            Icon(Icons.star_rounded, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              known ? label.substring(2) : label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookTitle(LibraryItem item) {
    final rereads = libraryRereads(item);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.book(ShelfPalette.of(context).text, size: 15),
          ),
        ),
        if (rereads > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Tooltip(
              message: 'Перечитываний: $rereads',
              child: Text(
                '×$rereads',
                style: TextStyle(
                  fontSize: 11,
                  color: ShelfPalette.of(context).muted,
                ),
              ),
            ),
          ),
      ],
    );
  }

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
              .showSnackBar(SnackBar(content: Text(describeError(error))));
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
      const PopupMenuItem(value: 'delete', child: Text('Удалить…')),
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
                    _bookTitle(item),
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
                        'Серия: ${_text(item.value('series'))}${item.value('seriesIndex') == null ? '' : ' · том ${_text(item.value('seriesIndex'))}'}',
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
                          if (libraryRating(item) != null) _rating(item),
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
                  child: _typeBadge(
                    item.mediaType == 'audiobook' ? 'АУДИО' : 'КНИГА',
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
                    _bookTitle(item),
                    const SizedBox(height: 3),
                    Text(
                      '${item.value('series') != null && item.value('seriesIndex') != null ? 'Том ${_text(item.value('seriesIndex'))} · ' : ''}${item.authors}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        // Shrinks instead of wrapping: the card height is exact.
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: _status(entry),
                          ),
                        ),
                        if (item.values['pepehub_favorite'] == true)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.favorite,
                              size: 14,
                              color: palette.accent,
                            ),
                          ),
                        if (libraryRating(item) != null) ...[
                          const SizedBox(width: 8),
                          Flexible(child: _rating(item)),
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
    Widget value(String label, dynamic value, {String empty = '—'}) {
      final text = _text(value).trim();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: palette.muted)),
          const SizedBox(height: 7),
          Text(
            text.isEmpty ? empty : text,
            style: TextStyle(
              fontSize: 11,
              color: text.isEmpty ? palette.muted : null,
            ),
          ),
        ],
      );
    }

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
          if (_text(item.values['narrator']).isNotEmpty) ...[
            const SizedBox(height: 14),
            value('Чтецы', item.values['narrator']),
          ],
          const SizedBox(height: 14),
          _progress(entry),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: value(
                  'Дата начала',
                  item.value('startDate'),
                  empty: 'Не указана',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: value(
                  'Дата завершения',
                  item.value('endDate'),
                  empty: 'Не указана',
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: value('Формат', libraryFormatName(item.value('format'))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: value(
                  'Ваша оценка',
                  libraryRating(item) == null ? '' : libraryRatingLabel(item),
                  empty: 'Без оценки',
                ),
              ),
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

  Widget _typeBadge(String label) {
    final palette = ShelfPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: .8,
          color: palette.text,
        ),
      ),
    );
  }

  Widget _goal() {
    final palette = ShelfPalette.of(context), year = DateTime.now().year;
    final finished = _yearBooks + _yearAudio;
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
                      'завершений книг и аудиокниг',
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
