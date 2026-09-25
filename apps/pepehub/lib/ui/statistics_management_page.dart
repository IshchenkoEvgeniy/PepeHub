import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';

import '../audio/audio_journal.dart';
import '../audio/audio_sidecar.dart';
import '../data/repository.dart';
import '../media/audio_controller.dart';
import '../reader/reading_library.dart';
import '../reader/reading_log.dart';

/// CRUD for the source records behind both statistics screens.
class StatisticsManagementPage extends StatefulWidget {
  final Repository repository;
  final AudioController? controller;
  final int initialTab;

  const StatisticsManagementPage({
    super.key,
    required this.repository,
    this.controller,
    this.initialTab = 0,
  });

  @override
  State<StatisticsManagementPage> createState() =>
      _StatisticsManagementPageState();
}

class _StatisticsManagementPageState extends State<StatisticsManagementPage>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  bool loading = true;
  List<_ReadingEntry> reading = [];
  List<LibraryRecord> audioEvents = [], legacyListening = [];
  List<LibraryRecord> readingBooks = [], audioBooks = [];
  Map<String, String> titles = {};
  Map<String, List<MapEntry<String, String>>> tracks = {};
  String? loadError;

  @override
  void initState() {
    super.initState();
    tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1).toInt(),
    );
    tabs.addListener(_tabChanged);
    _load();
  }

  void _tabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final repository = widget.repository;
      final library = ReadingLibrary(repository);
      final allBooks = await repository.records('book');
      final nextReadingBooks = allBooks
          .where((b) => b.payload?['format'] != 'audio')
          .toList();
      final nextAudioBooks = allBooks
          .where((b) => b.payload?['format'] == 'audio')
          .toList();
      final names = {for (final b in allBooks) b.id: b.title};
      final automatic = await library.entries('reading-session:');
      final nextReading = <_ReadingEntry>[
        for (final e in automatic.entries)
          _ReadingEntry(id: e.key, payload: e.value, automatic: true),
        for (final e in await repository.records('session'))
          if (e.payload?['kind'] == 'reading')
            _ReadingEntry(id: e.id, payload: e.payload!, automatic: false),
      ]..sort((a, b) => _dateOf(b.payload).compareTo(_dateOf(a.payload)));
      final nextEvents = await repository.records('audio_event');
      nextEvents.sort(
        (a, b) => _dateOf(b.payload ?? {}).compareTo(_dateOf(a.payload ?? {})),
      );
      final nextLegacy =
          (await repository.records('session'))
              .where((e) => e.payload?['kind'] == 'listening')
              .toList()
            ..sort(
              (a, b) =>
                  _dateOf(b.payload ?? {}).compareTo(_dateOf(a.payload ?? {})),
            );
      final trackRows = await repository.db
          .customSelect(
            'SELECT e.book_id,t.id,t.title FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id ORDER BY e.book_id,t.ordinal',
          )
          .get();
      final nextTracks = <String, List<MapEntry<String, String>>>{};
      for (final row in trackRows) {
        nextTracks
            .putIfAbsent(row.read<String>('book_id'), () => [])
            .add(MapEntry(row.read<String>('id'), row.read<String>('title')));
      }
      if (!mounted) return;
      setState(() {
        reading = nextReading;
        audioEvents = nextEvents;
        legacyListening = nextLegacy;
        readingBooks = nextReadingBooks;
        audioBooks = nextAudioBooks;
        titles = names;
        tracks = nextTracks;
        loadError = null;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loadError = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _report(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _load();
  }

  Future<void> _addEntry() async {
    if (tabs.index == 0) {
      if (readingBooks.isEmpty) {
        await _report('Сначала добавьте книгу для чтения.');
        return;
      }
      final value = await _manualSessionDialog(
        context,
        title: 'Добавить чтение',
        books: readingBooks,
        initialBookId: readingBooks.first.id,
        initialMinutes: 30,
      );
      if (value == null) return;
      try {
        final id = uuid.v4();
        final start = value.start.toUtc();
        final end = start.add(Duration(minutes: value.minutes));
        await widget.repository.put('session', id, {
          'bookId': value.bookId,
          'kind': 'reading',
          'startedAt': start.toIso8601String(),
          'endedAt': end.toIso8601String(),
          'activeSeconds': value.minutes * 60,
          'timezone': 'UTC',
          'source': 'manual',
        });
        await _report('Сессия чтения добавлена.');
      } catch (e) {
        await _report('Не удалось добавить сессию: $e');
      }
      return;
    }
    if (audioBooks.isEmpty) {
      await _report('Сначала добавьте аудиокнигу.');
      return;
    }
    final initialBook = audioBooks.first.id;
    final now = DateTime.now();
    final value = await _audioEventDialog(
      context,
      titles: titles,
      audioBookIds: audioBooks.map((e) => e.id).toList(),
      tracks: tracks,
      initial: {
        'version': 1,
        'kind': 'listen',
        'bookId': initialBook,
        'trackId': tracks[initialBook]?.firstOrNull?.key ?? '',
        'positionMs': 0,
        'endMs': 60000,
        'wallMs': 60000,
        'mediaMs': 60000,
        'speed': 1.0,
        'at': now.toUtc().toIso8601String(),
        'offsetMinutes': now.timeZoneOffset.inMinutes,
        'localDay': dayKey(now),
        'timezone': now.timeZoneName,
      },
      isNew: true,
    );
    if (value == null) return;
    try {
      await _flushLiveAudio();
      await AudioJournal(widget.repository)
          .put('audio_event', uuid.v4(), value);
      await _refreshAudioSidecar(value['bookId'] as String);
      await _report('Событие прослушивания добавлено.');
    } catch (e) {
      await _report('Запись не добавлена: $e');
    }
  }

  Future<void> _editReading(_ReadingEntry entry) async {
    final before = entry.payload;
    final edited = await _jsonEditor(
      context,
      title: entry.automatic
          ? 'Сессия чтения · ${titles[before['bookId']] ?? 'книга'}'
          : 'Ручная сессия чтения · ${titles[before['bookId']] ?? 'книга'}',
      initial: before,
      help: entry.automatic
          ? 'Можно изменить книгу, интервалы spans, время, символы, скорость и остальные поля записи.'
          : 'Можно изменить книгу, даты, активное время и остальные поля сессии.',
      validate: (value) => _validateReading(value, entry),
    );
    if (edited == null) return;
    try {
      if (entry.automatic) {
        await widget.repository.setMeta(
          'reading-session:${entry.id}',
          jsonEncode(edited),
        );
        await _refreshReadingLog(before);
        if (_readingLogDayChanged(before, edited)) {
          await _refreshReadingLog(edited);
        }
      } else {
        await widget.repository.put('session', entry.id, edited);
      }
      await _report('Сессия чтения сохранена.');
    } catch (e) {
      await _report('Сессия сохранена в базе, но журнал не обновлён: $e');
    }
  }

  String? _validateReading(Map<String, dynamic> value, _ReadingEntry entry) {
    if (value['bookId'] is! String ||
        (value['bookId'] as String).isEmpty ||
        DateTime.tryParse(value['startedAt'] as String? ?? '') == null ||
        DateTime.tryParse(value['endedAt'] as String? ?? '') == null ||
        !DateTime.parse(value['endedAt'] as String)
            .isAfter(DateTime.parse(value['startedAt'] as String))) {
      return 'Укажите книгу и корректные дату начала и окончания.';
    }
    if (entry.automatic) {
      if (value['id'] != entry.id || value['spans'] is! List) {
        return 'ID сессии должен совпадать, а spans должен быть списком.';
      }
      for (final raw in value['spans'] as List) {
        if (raw is! Map) return 'Каждый интервал должен быть объектом.';
        final span = Map<String, dynamic>.from(raw);
        final start = DateTime.tryParse(span['start'] as String? ?? '');
        final end = DateTime.tryParse(span['end'] as String? ?? '');
        if (start == null || end == null || !end.isAfter(start)) {
          return 'В каждом интервале конец должен быть позже начала.';
        }
        for (final key in ['activeMs', 'newChars', 'repeatChars']) {
          final number = span[key];
          if (number != null &&
              (number is! num || !number.isFinite || number < 0)) {
            return 'Поле $key должно быть неотрицательным числом.';
          }
        }
      }
    } else {
      final problem = _validateSyncedSession(value, 'reading');
      if (problem != null) return problem;
    }
    return null;
  }

  bool _readingLogDayChanged(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    return before['bookId'] != after['bookId'] ||
        _dateOf(before).toLocal().day != _dateOf(after).toLocal().day ||
        _dateOf(before).toLocal().month != _dateOf(after).toLocal().month ||
        _dateOf(before).toLocal().year != _dateOf(after).toLocal().year;
  }

  Future<void> _refreshReadingLog(Map<String, dynamic> value) async {
    await ReadingLog(widget.repository).export(value);
  }

  Future<void> _editAudioEvent(LibraryRecord record) async {
    final before = Map<String, dynamic>.from(record.payload!);
    final value = await _audioEventDialog(
      context,
      titles: titles,
      audioBookIds: audioBooks.map((e) => e.id).toList(),
      tracks: tracks,
      initial: before,
    );
    if (value == null) return;
    try {
      await _flushLiveAudio();
      await AudioJournal(widget.repository)
          .put('audio_event', record.id, value);
      await _refreshAudioSidecar(before['bookId'] as String?);
      if (before['bookId'] != value['bookId']) {
        await _refreshAudioSidecar(value['bookId'] as String);
      }
      await _report('Запись прослушивания сохранена.');
    } catch (e) {
      await _report('Запись сохранена в базе, но журнал не обновлён: $e');
    }
  }

  Future<void> _editAudioJson(LibraryRecord record) async {
    final before = Map<String, dynamic>.from(record.payload!);
    final edited = await _jsonEditor(
      context,
      title: 'Полная запись · ${_eventName(before['kind'] as String? ?? '')}',
      initial: before,
      help:
          'Расширенный редактор всех полей события. Время хранится в ISO 8601.',
      validate: _validateAudioEvent,
    );
    if (edited == null) return;
    try {
      await _flushLiveAudio();
      await AudioJournal(widget.repository)
          .put('audio_event', record.id, edited);
      await _refreshAudioSidecar(before['bookId'] as String?);
      if (before['bookId'] != edited['bookId']) {
        await _refreshAudioSidecar(edited['bookId'] as String);
      }
      await _report('Полная запись прослушивания сохранена.');
    } catch (e) {
      await _report('Запись сохранена в базе, но журнал не обновлён: $e');
    }
  }

  String? _validateAudioEvent(Map<String, dynamic> value) {
    if (value['kind'] is! String ||
        (value['kind'] as String).trim().isEmpty ||
        value['bookId'] is! String ||
        (value['bookId'] as String).isEmpty ||
        value['trackId'] is! String ||
        value['positionMs'] is! num ||
        (value['positionMs'] as num) < 0 ||
        DateTime.tryParse(value['at'] as String? ?? '') == null) {
      return 'Нужны тип события, книга, дорожка, позиция и дата.';
    }
    if (value['kind'] == 'listen') {
      if (value['endMs'] is! num ||
          (value['endMs'] as num) <= (value['positionMs'] as num) ||
          value['wallMs'] is! num ||
          (value['wallMs'] as num) <= 0 ||
          value['speed'] is! num ||
          (value['speed'] as num) < .5 ||
          (value['speed'] as num) > 3) {
        return 'Для прослушивания укажите конец, длительность и скорость 0,5–3×.';
      }
    }
    if (value['localDay'] is! String ||
        DateTime.tryParse('${value['localDay']}T00:00:00Z') == null ||
        value['offsetMinutes'] is! num) {
      return 'Укажите localDay и смещение часового пояса.';
    }
    return null;
  }

  Future<void> _editLegacyListening(LibraryRecord record) async {
    final value = await _jsonEditor(
      context,
      title: 'Старая сессия прослушивания',
      initial: record.payload!,
      help: 'Эти записи показываются отдельно и не прибавляются к новому журналу событий.',
      validate: (data) {
        return _validateSyncedSession(data, 'listening');
      },
    );
    if (value == null) return;
    try {
      await widget.repository.put('session', record.id, value);
      await _refreshAudioSidecar(record.payload?['bookId'] as String?);
      if (record.payload?['bookId'] != value['bookId']) {
        await _refreshAudioSidecar(value['bookId'] as String?);
      }
      await _report('Старая сессия обновлена.');
    } catch (e) {
      await _report('Не удалось сохранить сессию: $e');
    }
  }

  Future<void> _deleteEntry({
    required String title,
    required Future<void> Function() remove,
    Future<void> Function()? after,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text('«$title» перестанет учитываться в статистике.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await remove();
      await after?.call();
      await _report('Запись удалена.');
    } catch (e) {
      await _report('Запись удалена в приложении, но журнал не обновлён: $e');
    }
  }

  Future<void> _deleteReading(_ReadingEntry entry) => _deleteEntry(
    title:
        '${titles[entry.payload['bookId']] ?? 'Книга'} · ${_dateLabel(entry.payload['startedAt'])}',
    remove: () async {
      if (entry.automatic) {
        await widget.repository.db.customStatement(
          'DELETE FROM metadata WHERE key=?',
          ['reading-session:${entry.id}'],
        );
      } else {
        await widget.repository.delete('session', entry.id);
      }
    },
    after: entry.automatic ? () => _refreshReadingLog(entry.payload) : null,
  );

  Future<void> _deleteAudioEvent(LibraryRecord entry) => _deleteEntry(
    title:
        '${titles[entry.payload?['bookId']] ?? 'Книга'} · ${_eventName(entry.payload?['kind'] as String? ?? '')}',
    remove: () async {
      await _flushLiveAudio();
      await AudioJournal(widget.repository).deleteEvent(entry.id);
    },
    after: () => _refreshAudioSidecar(entry.payload?['bookId'] as String?),
  );

  Future<void> _deleteLegacy(LibraryRecord entry) => _deleteEntry(
    title:
        '${titles[entry.payload?['bookId']] ?? 'Книга'} · ${_dateLabel(entry.payload?['startedAt'])}',
    remove: () => widget.repository.delete('session', entry.id),
    after: () => _refreshAudioSidecar(entry.payload?['bookId'] as String?),
  );

  Future<void> _flushLiveAudio() async {
    final controller = widget.controller;
    if (controller == null) return;
    await controller.flushJournal();
    controller.journal.endInterval();
  }

  Future<void> _refreshAudioSidecar(String? bookId) async {
    if (bookId == null || widget.controller == null) return;
    await widget.controller!.sidecar.update(bookId, force: true);
  }

  Widget _readingItem(_ReadingEntry entry) {
    final data = entry.payload;
    final spans = data['spans'] as List? ?? const [];
    final ms = entry.automatic
        ? spans.fold<int>(
            0,
            (sum, raw) =>
                sum + (((raw as Map)['activeMs'] as num?)?.toInt() ?? 0),
          )
        : ((data['activeSeconds'] as num?)?.toInt() ?? 0) * 1000;
    final chars = entry.automatic
        ? spans.fold<int>(
                0,
                (sum, raw) =>
                    sum + (((raw as Map)['newChars'] as num?)?.toInt() ?? 0),
              ) +
              spans.fold<int>(
                0,
                (sum, raw) =>
                    sum + (((raw as Map)['repeatChars'] as num?)?.toInt() ?? 0),
              )
        : ((data['newChars'] as num?)?.toInt() ?? 0) +
              ((data['repeatChars'] as num?)?.toInt() ?? 0);
    final name = titles[data['bookId']] ?? 'Книга';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_dateLabel(data['startedAt'])} · ${_durationLabel(ms)} · $chars зн. · ${entry.automatic ? '${spans.length} интервалов' : 'ручная сессия'}',
        ),
        isThreeLine: false,
        trailing: PopupMenuButton<String>(
          tooltip: 'Действия',
          onSelected: (action) {
            if (action == 'edit') _editReading(entry);
            if (action == 'delete') _deleteReading(entry);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Редактировать все поля')),
            PopupMenuItem(
              value: 'delete',
              child: Text('Удалить из статистики'),
            ),
          ],
        ),
        onTap: () => _editReading(entry),
      ),
    );
  }

  Widget _audioItem(LibraryRecord record) {
    final data = record.payload!;
    final kind = data['kind'] as String? ?? 'event';
    final detail = kind == 'listen'
        ? '${_durationLabel((data['wallMs'] as num?)?.toInt() ?? 0)} · материал ${_durationLabel((((data['endMs'] as num?)?.toInt() ?? 0) - ((data['positionMs'] as num?)?.toInt() ?? 0)).clamp(0, 1 << 60).toInt())} · ${data['speed'] ?? 1}×'
        : 'Позиция ${_durationLabel((data['positionMs'] as num?)?.toInt() ?? 0)}';
    return Card(
      child: ListTile(
        leading: Icon(_eventIcon(kind)),
        title: Text(
          '${_eventName(kind)} · ${titles[data['bookId']] ?? 'Книга'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('${_dateLabel(data['at'])} · $detail'),
        trailing: PopupMenuButton<String>(
          tooltip: 'Действия',
          onSelected: (action) {
            if (action == 'edit') _editAudioEvent(record);
            if (action == 'json') _editAudioJson(record);
            if (action == 'delete') _deleteAudioEvent(record);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Изменить показатели')),
            PopupMenuItem(value: 'json', child: Text('Все поля · JSON')),
            PopupMenuItem(
              value: 'delete',
              child: Text('Удалить из статистики'),
            ),
          ],
        ),
        onTap: () => _editAudioEvent(record),
      ),
    );
  }

  Widget _legacyItem(LibraryRecord record) => Card(
    child: ListTile(
      leading: const Icon(Icons.history),
      title: Text(titles[record.payload?['bookId']] ?? 'Книга'),
      subtitle: Text(
        '${_dateLabel(record.payload?['startedAt'])} · ${_durationLabel(((record.payload?['activeSeconds'] as num?)?.toInt() ?? 0) * 1000)} · старый журнал',
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Действия',
        onSelected: (action) {
          if (action == 'edit') _editLegacyListening(record);
          if (action == 'delete') _deleteLegacy(record);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Редактировать все поля')),
          PopupMenuItem(
            value: 'delete',
            child: Text('Удалить из старого журнала'),
          ),
        ],
      ),
      onTap: () => _editLegacyListening(record),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Управление статистикой'),
      bottom: TabBar(
        controller: tabs,
        tabs: const [
          Tab(icon: Icon(Icons.menu_book_outlined), text: 'Чтение'),
          Tab(icon: Icon(Icons.headphones_outlined), text: 'Прослушивание'),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Обновить записи',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: loading ? null : _addEntry,
      icon: const Icon(Icons.add),
      label: Text(tabs.index == 0 ? 'Добавить чтение' : 'Добавить запись'),
    ),
    body: loading && reading.isEmpty && audioEvents.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              if (loadError != null)
                MaterialBanner(
                  content: Text(loadError!),
                  actions: [
                    TextButton(
                      onPressed: _load,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              if (loading) const LinearProgressIndicator(),
              Expanded(
                child: TabBarView(
                  controller: tabs,
                  children: [_readingList(), _audioList()],
                ),
              ),
            ],
          ),
  );

  Widget _readingList() => reading.isEmpty
      ? const Center(
          child: Text('Записей чтения пока нет. Добавьте сессию вручную.'),
        )
      : ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Автоматические интервалы и ручные сессии. Изменения пересчитывают время, продвижение и календарь.',
              ),
            ),
            for (final entry in reading) _readingItem(entry),
          ],
        );

  Widget _audioList() => audioEvents.isEmpty && legacyListening.isEmpty
      ? const Center(
          child: Text(
            'Событий прослушивания пока нет. Добавьте запись вручную.',
          ),
        )
      : ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Каждый интервал и событие влияет на свою часть статистики: время, материал, уникальные отрезки, серии, паузы, перемотки, закладки и таймеры. Нажмите запись, чтобы изменить поля; меню даёт полный JSON.',
              ),
            ),
            for (final entry in audioEvents) _audioItem(entry),
            if (legacyListening.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 20, 8, 8),
                child: Text(
                  'Старые ручные сессии · отдельно от новой статистики',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              for (final entry in legacyListening) _legacyItem(entry),
            ],
          ],
        );
}

class _ReadingEntry {
  final String id;
  final Map<String, dynamic> payload;
  final bool automatic;
  const _ReadingEntry({
    required this.id,
    required this.payload,
    required this.automatic,
  });
}

String? _validateSyncedSession(Map<String, dynamic> data, String kind) {
  const fields = {
    'bookId',
    'kind',
    'startedAt',
    'endedAt',
    'activeSeconds',
    'timezone',
    'source',
  };
  if (data.keys.any((key) => !fields.contains(key)) ||
      data['kind'] != kind ||
      data['bookId'] is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(data['bookId'] as String) ||
      data['timezone'] is! String ||
      (data['timezone'] as String).trim().isEmpty ||
      !const ['manual', 'timer', 'player'].contains(data['source'])) {
    return 'Проверьте книгу, тип сессии, часовой пояс и источник.';
  }
  final startText = data['startedAt'] as String?;
  final endText = data['endedAt'] as String?;
  final start = DateTime.tryParse(startText ?? ''),
      end = DateTime.tryParse(endText ?? '');
  final seconds = data['activeSeconds'];
  if (start == null ||
      end == null ||
      !start.isUtc ||
      !end.isUtc ||
      !startText!.endsWith('Z') ||
      !endText!.endsWith('Z') ||
      end.isBefore(start) ||
      end.difference(start) > const Duration(days: 7) ||
      seconds is! int ||
      seconds < 0 ||
      seconds > end.difference(start).inSeconds) {
    return 'Даты должны быть в UTC, интервал — до 7 дней, активное время не может превышать его длительность.';
  }
  return null;
}

DateTime _dateOf(Map<String, dynamic> data) =>
    DateTime.tryParse(
      data['startedAt'] as String? ?? data['at'] as String? ?? '',
    ) ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

String _durationLabel(int milliseconds) {
  final minutes = milliseconds ~/ 60000;
  return minutes >= 60
      ? '${minutes ~/ 60} ч ${minutes % 60} мин'
      : minutes > 0
      ? '$minutes мин'
      : '${milliseconds ~/ 1000} с';
}

String _dateLabel(Object? value) {
  final date = DateTime.tryParse(value as String? ?? '')?.toLocal();
  if (date == null) return 'дата не указана';
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

IconData _eventIcon(String kind) => switch (kind) {
  'listen' => Icons.headphones,
  'pause' => Icons.pause_circle_outline,
  'seek' => Icons.fast_forward,
  'bookmark' => Icons.bookmark_outline,
  'completed' || 'chapter_completed' => Icons.check_circle_outline,
  'error' => Icons.error_outline,
  'buffering' => Icons.network_check,
  _ => Icons.history,
};

String _eventName(String kind) =>
    const {
      'listen': 'Прослушивание',
      'chapter_completed': 'Завершена глава',
      'play': 'Воспроизведение',
      'pause': 'Пауза',
      'stop': 'Остановка',
      'seek': 'Перемотка',
      'speed': 'Скорость',
      'bookmark': 'Закладка',
      'sleep_set': 'Таймер установлен',
      'sleep_fired': 'Таймер сработал',
      'sleep_extended': 'Таймер продлён',
      'sleep_cancelled': 'Таймер отменён',
      'completed': 'Конец книги',
      'track_changed': 'Смена трека',
      'buffering': 'Буферизация',
      'error': 'Ошибка',
    }[kind] ??
    kind;

const _eventKinds = [
  'listen',
  'play',
  'pause',
  'stop',
  'seek',
  'speed',
  'bookmark',
  'sleep_set',
  'sleep_fired',
  'sleep_extended',
  'sleep_cancelled',
  'chapter_completed',
  'completed',
  'track_changed',
  'buffering',
  'error',
];

Future<Map<String, dynamic>?> _jsonEditor(
  BuildContext context, {
  required String title,
  required Map<String, dynamic> initial,
  required String help,
  required String? Function(Map<String, dynamic>) validate,
}) async {
  final controller = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(initial),
  );
  String? error;
  try {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(help),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    minLines: 10,
                    maxLines: 22,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Все данные записи · JSON',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final decoded = jsonDecode(controller.text);
                  if (decoded is! Map) {
                    setState(() => error = 'Ожидается JSON-объект.');
                    return;
                  }
                  final data = Map<String, dynamic>.from(decoded);
                  final problem = validate(data);
                  if (problem != null) {
                    setState(() => error = problem);
                    return;
                  }
                  Navigator.pop(context, data);
                } catch (e) {
                  setState(() => error = 'Некорректный JSON: $e');
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  } finally {
    controller.dispose();
  }
}

class _ManualSessionValue {
  final String bookId;
  final DateTime start;
  final int minutes;
  const _ManualSessionValue(this.bookId, this.start, this.minutes);
}

Future<_ManualSessionValue?> _manualSessionDialog(
  BuildContext context, {
  required String title,
  required List<LibraryRecord> books,
  required String initialBookId,
  required int initialMinutes,
}) async {
  String bookId = initialBookId;
  DateTime start = DateTime.now().subtract(Duration(minutes: initialMinutes));
  var minutes = '$initialMinutes';
  return showDialog<_ManualSessionValue>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: bookId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Книга'),
                  items: [
                    for (final book in books)
                      DropdownMenuItem(value: book.id, child: Text(book.title)),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => bookId = value);
                  },
                ),
                _DateTimeTile(
                  title: 'Начало',
                  value: start,
                  onChanged: (value) {
                    if (value != null) setState(() => start = value);
                  },
                ),
                TextFormField(
                  initialValue: minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Активное время, минут',
                  ),
                  onChanged: (value) => minutes = value,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final duration = int.tryParse(minutes);
              if (duration == null || duration < 1 || duration > 1440) return;
              Navigator.pop(
                context,
                _ManualSessionValue(bookId, start, duration),
              );
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    ),
  );
}

class _DateTimeTile extends StatelessWidget {
  final String title;
  final DateTime value;
  final ValueChanged<DateTime?> onChanged;
  const _DateTimeTile({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(_dateLabel(value.toIso8601String())),
    trailing: const Icon(Icons.edit_calendar_outlined),
    onTap: () async {
      final date = await showDatePicker(
        context: context,
        initialDate: value,
        firstDate: DateTime(1900),
        lastDate: DateTime(2200),
      );
      if (date == null || !context.mounted) return;
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(value),
      );
      if (time == null) return;
      onChanged(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      );
    },
  );
}

Future<Map<String, dynamic>?> _audioEventDialog(
  BuildContext context, {
  required Map<String, String> titles,
  required List<String> audioBookIds,
  required Map<String, List<MapEntry<String, String>>> tracks,
  required Map<String, dynamic> initial,
  bool isNew = false,
}) async {
  final data = Map<String, dynamic>.from(initial);
  var bookId = data['bookId'] as String? ?? audioBookIds.firstOrNull ?? '';
  var trackId = data['trackId'] as String? ?? '';
  var kind = data['kind'] as String? ?? 'listen';
  var at =
      DateTime.tryParse(data['at'] as String? ?? '')?.toLocal() ??
      DateTime.now();
  final position = TextEditingController(text: '${data['positionMs'] ?? 0}');
  final end = TextEditingController(text: '${data['endMs'] ?? 60000}');
  final wall = TextEditingController(text: '${data['wallMs'] ?? 60000}');
  final speed = TextEditingController(text: '${data['speed'] ?? 1}');
  final from = TextEditingController(text: '${data['fromMs'] ?? 0}');
  final fromTrack = TextEditingController(
    text: '${data['fromTrackId'] ?? trackId}',
  );
  String? error;
  try {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final choices = tracks[bookId] ?? const <MapEntry<String, String>>[];
          final currentTrackExists = choices.any((e) => e.key == trackId);
          return AlertDialog(
            title: Text(isNew ? 'Добавить событие' : 'Изменить событие'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: kind,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Что учитывать',
                      ),
                      items: [
                        for (final value in {..._eventKinds, kind})
                          DropdownMenuItem(
                            value: value,
                            child: Text(_eventName(value)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => kind = value);
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: bookId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Книга'),
                      items: [
                        for (final id in {...audioBookIds, bookId})
                          DropdownMenuItem(
                            value: id,
                            child: Text(titles[id] ?? '$id · архив'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          bookId = value;
                          final next =
                              tracks[bookId] ??
                              const <MapEntry<String, String>>[];
                          if (next.isNotEmpty &&
                              !next.any((e) => e.key == trackId))
                            trackId = next.first.key;
                        });
                      },
                    ),
                    if (choices.isNotEmpty)
                      DropdownButtonFormField<String>(
                        initialValue: currentTrackExists ? trackId : null,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Дорожка'),
                        items: [
                          if (!currentTrackExists && trackId.isNotEmpty)
                            DropdownMenuItem(
                              value: trackId,
                              child: Text('$trackId · архивная'),
                            ),
                          for (final choice in choices)
                            DropdownMenuItem(
                              value: choice.key,
                              child: Text(choice.value),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => trackId = value);
                        },
                      )
                    else
                      TextFormField(
                        initialValue: trackId,
                        decoration: const InputDecoration(
                          labelText: 'ID дорожки',
                        ),
                        onChanged: (value) => trackId = value,
                      ),
                    _DateTimeTile(
                      title: 'Дата и время',
                      value: at,
                      onChanged: (value) {
                        if (value != null) setState(() => at = value);
                      },
                    ),
                    TextField(
                      controller: position,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Позиция, мс',
                      ),
                    ),
                    if (kind == 'listen') ...[
                      TextField(
                        controller: end,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Конец отрезка, мс',
                        ),
                      ),
                      TextField(
                        controller: wall,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Активное время, мс',
                        ),
                      ),
                      TextField(
                        controller: speed,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Скорость, от 0,5 до 3×',
                        ),
                      ),
                    ],
                    if (kind == 'seek') ...[
                      TextField(
                        controller: from,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Начальная позиция, мс',
                        ),
                      ),
                      TextField(
                        controller: fromTrack,
                        decoration: const InputDecoration(
                          labelText: 'ID дорожки до перехода',
                        ),
                      ),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final pos = int.tryParse(position.text),
                      endMs = int.tryParse(end.text),
                      wallMs = int.tryParse(wall.text),
                      seekFrom = int.tryParse(from.text),
                      rate = double.tryParse(speed.text.replaceAll(',', '.'));
                  if (bookId.isEmpty ||
                      trackId.trim().isEmpty ||
                      pos == null ||
                      pos < 0) {
                    setState(
                      () =>
                          error = 'Выберите книгу и дорожку, укажите позицию.',
                    );
                    return;
                  }
                  if (kind == 'listen' &&
                      (endMs == null ||
                          endMs <= pos ||
                          wallMs == null ||
                          wallMs <= 0 ||
                          rate == null ||
                          rate < .5 ||
                          rate > 3)) {
                    setState(
                      () => error =
                          'Проверьте конец, активное время и скорость 0,5–3×.',
                    );
                    return;
                  }
                  if (kind == 'seek' && (seekFrom == null || seekFrom < 0)) {
                    setState(
                      () => error = 'Укажите начальную позицию перемотки.',
                    );
                    return;
                  }
                  final utc = at.toUtc();
                  final offset = at.timeZoneOffset.inMinutes;
                  final updated = <String, dynamic>{
                    ...data,
                    'version': data['version'] ?? 1,
                    'kind': kind,
                    'bookId': bookId,
                    'trackId': trackId.trim(),
                    'positionMs': pos,
                    'at': utc.toIso8601String(),
                    'offsetMinutes': offset,
                    'localDay': dayKey(utc.add(Duration(minutes: offset))),
                    'timezone': at.timeZoneName,
                  };
                  if (kind == 'listen') {
                    updated.addAll({
                      'endMs': endMs,
                      'wallMs': wallMs,
                      'mediaMs': endMs! - pos,
                      'speed': rate,
                    });
                    updated.remove('fromMs');
                    updated.remove('fromTrackId');
                  } else if (kind == 'seek') {
                    updated['fromMs'] = seekFrom;
                    updated['fromTrackId'] = fromTrack.text.trim();
                    updated.remove('endMs');
                    updated.remove('wallMs');
                    updated.remove('mediaMs');
                    updated.remove('speed');
                  } else {
                    updated.remove('endMs');
                    updated.remove('wallMs');
                    updated.remove('mediaMs');
                    updated.remove('speed');
                    updated.remove('fromMs');
                    updated.remove('fromTrackId');
                  }
                  final problem = _validateAudioData(updated);
                  if (problem != null) {
                    setState(() => error = problem);
                    return;
                  }
                  Navigator.pop(context, updated);
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    position.dispose();
    end.dispose();
    wall.dispose();
    speed.dispose();
    from.dispose();
    fromTrack.dispose();
  }
}

String? _validateAudioData(Map<String, dynamic> value) {
  if (value['kind'] is! String ||
      value['bookId'] is! String ||
      (value['bookId'] as String).isEmpty ||
      value['trackId'] is! String ||
      value['positionMs'] is! num ||
      (value['positionMs'] as num) < 0 ||
      DateTime.tryParse(value['at'] as String? ?? '') == null) {
    return 'Нужны тип события, книга, дорожка, позиция и дата.';
  }
  if (value['kind'] == 'listen' &&
      (value['endMs'] is! num ||
          (value['endMs'] as num) <= (value['positionMs'] as num) ||
          value['wallMs'] is! num ||
          (value['wallMs'] as num) <= 0 ||
          value['speed'] is! num ||
          (value['speed'] as num) < .5 ||
          (value['speed'] as num) > 3)) {
    return 'Интервал прослушивания некорректен.';
  }
  if (value['localDay'] is! String ||
      DateTime.tryParse('${value['localDay']}T00:00:00Z') == null ||
      value['offsetMinutes'] is! num) {
    return 'Нужны корректная дата и смещение часового пояса.';
  }
  return null;
}
