import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import 'activity_page.dart';
import 'app_theme.dart';
import 'obsidian_library_page.dart' show LibraryMetadataEditor, libraryState;
import 'shelf_components.dart';

num? _number(dynamic value) => value is num ? value : num.tryParse('$value');
String _text(dynamic value) =>
    value is List ? value.join(', ') : '${value ?? ''}';
String _amount(num? value) => value == null
    ? '—'
    : value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

String metadataReadingStatus(ObsidianLibraryItem item) {
  final status = _text(item.value('status')).toLowerCase().trim();
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
  final minutes = value.round();
  if (minutes < 60) return '$minutes мин';
  final hours = minutes ~/ 60, remainder = minutes % 60;
  return remainder == 0 ? '$hours ч' : '$hours ч $remainder мин';
}

String metadataProgressLabel(ObsidianLibraryItem item) {
  final total = _number(item.value('total')),
      progress = _number(item.value('progress'));
  final unit = _text(item.value('unit'));
  if (total == null && progress == null) return 'Прогресс не указан';
  if (item.mediaType == 'audiobook' &&
      (unit.isEmpty ||
          [
            'minutes',
            'minute',
            'мин',
            'минуты',
          ].contains(unit.toLowerCase()))) {
    return progress == null
        ? _duration(total!)
        : total == null
        ? _duration(progress)
        : '${_duration(progress)} / ${_duration(total)}';
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
  String type = 'all', scope = 'all', status = 'all', sort = 'recent';
  String? selectedId;
  bool filters = false, grid = true;
  int? annualGoal;
  String? goalNamespace;
  @override
  void initState() {
    super.initState();
    unawaited(_loadGoal());
  }

  @override
  void dispose() {
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  String get _goalKey =>
      'library-year-goal:${widget.service.config?.namespace ?? 'unconnected'}:${DateTime.now().year}';
  Future<void> _loadGoal() async {
    final namespace = widget.service.config?.namespace;
    final raw = await widget.service.local.meta(_goalKey);
    if (mounted && namespace == widget.service.config?.namespace) {
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

  Future<void> _open(LibraryEntry entry) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => LibraryMetadataEditor(
        onPickCover: widget.service.chooseCover,
        item: entry.item,
        entry: entry,
        onSave: (values) => widget.service.save(
          entry.item.id,
          values,
          original: entry.item.values,
        ),
        onUseObsidian: () => widget.service.useObsidian(entry.item.id),
      ),
    ),
  );
  bool _matches(LibraryEntry entry) {
    final item = entry.item;
    final texts = {
      'title': item.title,
      'author': item.authors,
      'series': _text(item.value('series')),
      'all': [
        item.title,
        item.authors,
        _text(item.value('series')),
        _text(item.value('genre')),
        _text(item.values['tags']),
      ].join(' '),
    };
    final haystack = (texts[scope] ?? '').toLowerCase().replaceAll('ё', 'е');
    final terms = search.text
        .trim()
        .toLowerCase()
        .replaceAll('ё', 'е')
        .split(RegExp(r'\s+'));
    return (type == 'all' || item.mediaType == type) &&
        (status == 'all' || metadataReadingStatus(item) == status) &&
        terms.every(haystack.contains);
  }

  int _compare(LibraryEntry a, LibraryEntry b) {
    final left = a.item, right = b.item;
    final compared = switch (sort) {
      'author' => left.authors.toLowerCase().compareTo(
        right.authors.toLowerCase(),
      ),
      'series' => _text(
        left.value('series'),
      ).toLowerCase().compareTo(_text(right.value('series')).toLowerCase()),
      'progress' => (metadataProgress(right) ?? -1).compareTo(
        metadataProgress(left) ?? -1,
      ),
      'rating' => (_number(right.value('rating')) ?? -1).compareTo(
        _number(left.value('rating')) ?? -1,
      ),
      'recent' => right.modifiedAt.compareTo(left.modifiedAt),
      _ => left.title.toLowerCase().compareTo(right.title.toLowerCase()),
    };
    return compared == 0
        ? left.title.toLowerCase().compareTo(right.title.toLowerCase())
        : compared;
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
        final all = service.entries;
        final entries = all.where(_matches).toList()..sort(_compare);
        final selected =
            entries.where((e) => e.item.id == selectedId).firstOrNull ??
            entries.firstOrNull;
        final books = all.where((e) => e.item.mediaType == 'book').length,
            audio = all.length - books;
        int count(String key) =>
            all.where((e) => metadataReadingStatus(e.item) == key).length;
        return ShelfShell(
          title: 'Библиотека',
          navigation: widget.navigation,
          actions: [
            IconButton(
              tooltip: 'Журнал чтения и прослушивания',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ActivityPage(library: service),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Подключение Obsidian',
              onPressed: widget.onSettings,
              icon: const Icon(Icons.link, size: 20),
            ),
          ],
          body: LayoutBuilder(
            builder: (context, constraints) {
              const inset = 20.0;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(inset, 4, inset, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShelfIntro(
                      title: 'Библиотека',
                      subtitle: 'Ваше чтение — в порядке.',
                      action: OutlinedButton.icon(
                        onPressed: service.syncing || service.config == null
                            ? null
                            : service.sync,
                        icon: service.syncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync_rounded, size: 17),
                        label: const Text('Синхронизировать'),
                      ),
                    ),
                    const SizedBox(height: 22),
                    _goal(all),
                    const SizedBox(height: 18),
                    ShelfSummary(
                      total: all.length,
                      books: books,
                      audio: audio,
                      active: count('active'),
                      finished: count('finished'),
                      planned: count('planned'),
                      selected: status,
                      onStatus: (next) => setState(() => status = next),
                    ),
                    const SizedBox(height: 24),
                    if (service.config == null) ...[
                      ShelfPanel(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Ваша библиотека Obsidian — здесь',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Подключите Obsidian, чтобы автоматически получать книги и аудиокниги из его библиотеки.',
                              style: TextStyle(color: palette.muted),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: widget.onSettings,
                              icon: const Icon(
                                Icons.diamond_outlined,
                                size: 16,
                              ),
                              label: const Text('Подключить Obsidian'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (service.error != null) ...[
                      ShelfPanel(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(service.error!)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    LayoutBuilder(
                      builder: (context, content) {
                        final details = content.maxWidth >= 1000;
                        final collection = _collection(
                          entries,
                          all,
                          selected,
                          details,
                        );
                        if (!details) return collection;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: collection),
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 300,
                              child: selected != null
                                  ? _detail(selected)
                                  : ShelfPanel(
                                      padding: const EdgeInsets.all(22),
                                      child: Text(
                                        'Выберите запись из коллекции',
                                        style: TextStyle(color: palette.muted),
                                      ),
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    ),
  );
  Widget _collection(
    List<LibraryEntry> entries,
    List<LibraryEntry> all,
    LibraryEntry? selected,
    bool details,
  ) {
    final palette = ShelfPalette.of(context);
    final pill = OutlineInputBorder(
      borderRadius: BorderRadius.circular(26),
      borderSide: BorderSide(color: palette.line),
    );
    final field = TextField(
      key: const ValueKey('library-search'),
      controller: search,
      focusNode: searchFocus,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Название, автор или серия…',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить поиск',
                onPressed: () => setState(search.clear),
                icon: const Icon(Icons.close, size: 17),
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
                  children: [field, const SizedBox(height: 10), selector],
                )
              : Row(
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: 10),
                    SizedBox(width: 160, child: selector),
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
            OutlinedButton.icon(
              onPressed: () => setState(() => filters = !filters),
              icon: Icon(
                filters ? Icons.close : Icons.filter_list_rounded,
                size: 15,
              ),
              label: Text(status == 'all' ? 'Фильтры' : 'Фильтры · 1'),
            ),
          ],
        ),
        if (filters)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: DropdownButtonFormField<String>(
              key: ValueKey('library-status:$status'),
              initialValue: status,
              decoration: const InputDecoration(
                labelText: 'Статус',
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('Любой статус')),
                DropdownMenuItem(value: 'active', child: Text('В процессе')),
                DropdownMenuItem(value: 'finished', child: Text('Завершено')),
                DropdownMenuItem(value: 'planned', child: Text('В планах')),
                DropdownMenuItem(
                  value: 'other',
                  child: Text('Другой / не указан'),
                ),
              ],
              onChanged: (next) => setState(() => status = next ?? 'all'),
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
                onChanged: (next) => setState(() => sort = next ?? 'recent'),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Показано ${entries.length} из ${all.length}',
              style: TextStyle(fontSize: 12, color: palette.muted),
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
        if (entries.isEmpty)
          ShelfPanel(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Column(
              children: [
                Icon(Icons.search_off_outlined, size: 36, color: palette.muted),
                const SizedBox(height: 14),
                Text(
                  all.isEmpty
                      ? 'В библиотеке пока нет записей'
                      : 'Ничего не найдено',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (all.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    'Попробуйте другой запрос или сбросьте фильтры.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      search.clear();
                      type = status = scope = 'all';
                    }),
                    child: const Text('Сбросить фильтры'),
                  ),
                ],
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              if (grid) {
                const gap = 16.0;
                final columns = (constraints.maxWidth / 200).floor().clamp(
                  2,
                  8,
                );
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
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
                  itemBuilder: (_, i) => _gridCard(
                    entries[i],
                    selected?.item.id == entries[i].item.id,
                    details,
                    width,
                  ),
                );
              }
              final table = constraints.maxWidth >= 620;
              return ShelfPanel(
                child: Column(
                  children: [
                    if (table) _tableHeader(),
                    for (final entry in entries)
                      _row(
                        entry,
                        selected?.item.id == entry.item.id,
                        details,
                        table,
                      ),
                  ],
                ),
              );
            },
          ),
      ],
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
                child: IconButton(
                  tooltip: 'Редактировать метаданные',
                  onPressed: () => _open(entry),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz, size: 18),
                ),
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
                onPressed: () => _open(entry),
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
            label: const Text('Редактировать метаданные'),
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
              Icon(Icons.diamond_outlined, size: 12, color: palette.accent),
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
    final ticks = goal == null ? 0 : goal.clamp(1, 60);
    final done = goal == null
        ? 0
        : (finished * ticks / goal).floor().clamp(0, ticks);
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
                    if (goal != null)
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
          if (goal != null) ...[
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
            child: Text(goal == null ? 'Задать цель' : 'Изменить цель'),
          ),
        ],
      ),
    );
  }
}
