import 'dart:convert';

import 'package:flutter/material.dart';

import '../sync/peer/app_sync_usage.dart';

import 'audio_mini_player.dart';

import 'package:flutter/services.dart';

import '../audio/audio_journal.dart';
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
  void Function()? _releaseSync;
  late final TabController tabs;
  bool loading = true;
  List<_ReadingEntry> reading = [];
  List<LibraryRecord> audioEvents = [], legacyListening = [];
  List<LibraryRecord> readingBooks = [], audioBooks = [];
  Map<String, String> titles = {};
  Map<String, List<MapEntry<String, String>>> tracks = {};
  String? loadError;
  final search = TextEditingController();
  String? selectedBookId;
  String typeFilter = 'all';
  int periodDays = 0;
  bool newestFirst = true;
  final Set<String> selectedEntries = {};

  @override
  void initState() {
    super.initState();
    _releaseSync = AppSyncUsage.hold(widget.repository.db, 'statistics-edit');
    tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1).toInt(),
    );
    tabs.addListener(_tabChanged);
    _load();
  }

  void _tabChanged() {
    if (mounted && !tabs.indexIsChanging) {
      setState(() {
        selectedBookId = null;
        typeFilter = 'all';
        selectedEntries.clear();
      });
    }
  }

  @override
  void dispose() {
    _releaseSync?.call();
    search.dispose();
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
      var saved = false;
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
        saved = true;
        await _refreshReadingLog({
          'bookId': value.bookId,
          'startedAt': start.toIso8601String(),
        });
        await _report('Сессия чтения добавлена.');
      } catch (e) {
        await _report(
          saved
              ? 'Сессия добавлена, но журнал папки не обновлён: $e'
              : 'Не удалось добавить сессию: $e',
        );
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
        await _refreshReadingLog(before);
        if (_readingLogDayChanged(before, edited)) {
          await _refreshReadingLog(edited);
        }
      }
      await _report('Сессия чтения сохранена.');
    } catch (e) {
      await _report('Сессия сохранена в базе, но журнал не обновлён: $e');
    }
  }

  Future<void> _editManualReading(_ReadingEntry entry) async {
    final before = entry.payload;
    if (readingBooks.every((book) => book.id != before['bookId'])) {
      await _editReading(entry);
      return;
    }
    final start =
        DateTime.tryParse(before['startedAt'] as String? ?? '')?.toLocal() ??
        DateTime.now();
    final minutes = (((before['activeSeconds'] as num?)?.toInt() ?? 1800) / 60)
        .round()
        .clamp(1, 1440);
    final value = await _manualSessionDialog(
      context,
      title: 'Изменить сессию чтения',
      books: readingBooks,
      initialBookId: before['bookId'] as String,
      initialMinutes: minutes,
      initialStart: start,
      submitLabel: 'Сохранить',
    );
    if (value == null) return;
    final utcStart = value.start.toUtc();
    final updated = {
      ...before,
      'bookId': value.bookId,
      'startedAt': utcStart.toIso8601String(),
      'endedAt': utcStart
          .add(Duration(minutes: value.minutes))
          .toIso8601String(),
      'activeSeconds': value.minutes * 60,
    };
    var saved = false;
    try {
      await widget.repository.put('session', entry.id, updated);
      saved = true;
      await _refreshReadingLog(before);
      if (_readingLogDayChanged(before, updated)) {
        await _refreshReadingLog(updated);
      }
      await _report('Сессия чтения сохранена.');
    } catch (e) {
      await _report(
        saved
            ? 'Сессия сохранена, но журнал папки не обновлён: $e'
            : 'Не удалось сохранить сессию: $e',
      );
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
    after: () => _refreshReadingLog(entry.payload),
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

  void _toggleEntry(String key) => setState(() {
    if (!selectedEntries.add(key)) selectedEntries.remove(key);
  });

  List<String> _visibleKeys() => tabs.index == 0
      ? [for (final entry in _visibleReading()) 'reading:${entry.id}']
      : [
          for (final row in _visibleAudioRows())
            '${row.legacy ? 'legacy' : 'audio'}:${row.record.id}',
        ];

  Future<void> _deleteSelected() async {
    final keys = {...selectedEntries};
    if (keys.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить ${keys.length} записей?'),
        content: const Text(
          'Выбранные записи перестанут учитываться в статистике. Журналы подключённых папок обновятся.',
        ),
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
    final readingDays = <Map<String, dynamic>>[];
    final audioBooksChanged = <String>{};
    var deleted = 0;
    try {
      if (tabs.index == 1) await _flushLiveAudio();
      for (final entry in reading) {
        if (!keys.contains('reading:${entry.id}')) continue;
        if (entry.automatic) {
          await widget.repository.db.customStatement(
            'DELETE FROM metadata WHERE key=?',
            ['reading-session:${entry.id}'],
          );
        } else {
          await widget.repository.delete('session', entry.id);
        }
        readingDays.add(entry.payload);
        deleted++;
      }
      for (final entry in audioEvents) {
        if (!keys.contains('audio:${entry.id}')) continue;
        await AudioJournal(widget.repository).deleteEvent(entry.id);
        if (entry.payload?['bookId'] is String) {
          audioBooksChanged.add(entry.payload!['bookId'] as String);
        }
        deleted++;
      }
      for (final entry in legacyListening) {
        if (!keys.contains('legacy:${entry.id}')) continue;
        await widget.repository.delete('session', entry.id);
        if (entry.payload?['bookId'] is String) {
          audioBooksChanged.add(entry.payload!['bookId'] as String);
        }
        deleted++;
      }
      for (final row in readingDays) {
        await _refreshReadingLog(row);
      }
      for (final bookId in audioBooksChanged) {
        await _refreshAudioSidecar(bookId);
      }
      if (mounted) setState(selectedEntries.clear);
      await _report('Удалено записей: $deleted');
    } catch (e) {
      if (mounted) setState(selectedEntries.clear);
      await _report(
        'Удалено $deleted из ${keys.length}; проверьте оставшиеся записи: $e',
      );
    }
  }

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
        leading: selectedEntries.isEmpty
            ? const Icon(Icons.menu_book_outlined)
            : Checkbox(
                value: selectedEntries.contains('reading:${entry.id}'),
                onChanged: (_) => _toggleEntry('reading:${entry.id}'),
              ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_dateLabel(data['startedAt'])} · ${_durationLabel(ms)} · $chars зн. · ${entry.automatic ? '${spans.length} интервалов' : 'ручная сессия'}',
        ),
        isThreeLine: false,
        trailing: selectedEntries.isNotEmpty
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Действия',
                onSelected: (action) {
                  if (action == 'edit') {
                    entry.automatic
                        ? _editReading(entry)
                        : _editManualReading(entry);
                  }
                  if (action == 'json') _editReading(entry);
                  if (action == 'delete') _deleteReading(entry);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(
                      entry.automatic
                          ? 'Редактировать все поля'
                          : 'Изменить дату и время',
                    ),
                  ),
                  if (!entry.automatic)
                    const PopupMenuItem(
                      value: 'json',
                      child: Text('Все поля · JSON'),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить из статистики'),
                  ),
                ],
              ),
        onLongPress: () => _toggleEntry('reading:${entry.id}'),
        onTap: selectedEntries.isNotEmpty
            ? () => _toggleEntry('reading:${entry.id}')
            : () => entry.automatic
                  ? _editReading(entry)
                  : _editManualReading(entry),
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
        leading: selectedEntries.isEmpty
            ? Icon(_eventIcon(kind))
            : Checkbox(
                value: selectedEntries.contains('audio:${record.id}'),
                onChanged: (_) => _toggleEntry('audio:${record.id}'),
              ),
        title: Text(
          '${_eventName(kind)} · ${titles[data['bookId']] ?? 'Книга'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('${_dateLabel(data['at'])} · $detail'),
        trailing: selectedEntries.isNotEmpty
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Действия',
                onSelected: (action) {
                  if (action == 'edit') _editAudioEvent(record);
                  if (action == 'json') _editAudioJson(record);
                  if (action == 'delete') _deleteAudioEvent(record);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Изменить показатели'),
                  ),
                  PopupMenuItem(value: 'json', child: Text('Все поля · JSON')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить из статистики'),
                  ),
                ],
              ),
        onLongPress: () => _toggleEntry('audio:${record.id}'),
        onTap: selectedEntries.isNotEmpty
            ? () => _toggleEntry('audio:${record.id}')
            : () => _editAudioEvent(record),
      ),
    );
  }

  Widget _legacyItem(LibraryRecord record) => Card(
    child: ListTile(
      leading: selectedEntries.isEmpty
          ? const Icon(Icons.history)
          : Checkbox(
              value: selectedEntries.contains('legacy:${record.id}'),
              onChanged: (_) => _toggleEntry('legacy:${record.id}'),
            ),
      title: Text(titles[record.payload?['bookId']] ?? 'Книга'),
      subtitle: Text(
        '${_dateLabel(record.payload?['startedAt'])} · ${_durationLabel(((record.payload?['activeSeconds'] as num?)?.toInt() ?? 0) * 1000)} · старый журнал',
      ),
      trailing: selectedEntries.isNotEmpty
          ? null
          : PopupMenuButton<String>(
              tooltip: 'Действия',
              onSelected: (action) {
                if (action == 'edit') _editLegacyListening(record);
                if (action == 'delete') _deleteLegacy(record);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'edit',
                  child: Text('Редактировать все поля'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Удалить из старого журнала'),
                ),
              ],
            ),
      onLongPress: () => _toggleEntry('legacy:${record.id}'),
      onTap: selectedEntries.isNotEmpty
          ? () => _toggleEntry('legacy:${record.id}')
          : () => _editLegacyListening(record),
    ),
  );

  bool _matchesEntry(Map<String, dynamic> data, String label) {
    if (selectedBookId != null && data['bookId'] != selectedBookId) {
      return false;
    }
    if (periodDays > 0 &&
        _dateOf(data)
            .isBefore(DateTime.now().subtract(Duration(days: periodDays)))) {
      return false;
    }
    final query = search.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return '${titles[data['bookId']] ?? ''} $label ${_dateLabel(data['startedAt'] ?? data['at'])} ${data['bookId'] ?? ''}'
        .toLowerCase()
        .contains(query);
  }

  List<_ReadingEntry> _visibleReading() {
    final result = reading.where((entry) {
      if (typeFilter == 'automatic' && !entry.automatic ||
          typeFilter == 'manual' && entry.automatic) {
        return false;
      }
      return _matchesEntry(
        entry.payload,
        entry.automatic ? 'автоматическая сессия' : 'ручная сессия',
      );
    }).toList();
    if (!newestFirst) return result.reversed.toList();
    return result;
  }

  List<LibraryRecord> _visibleAudioEvents() {
    if (typeFilter == 'legacy') return [];
    final result = audioEvents.where((entry) {
      final data = entry.payload ?? {};
      final kind = data['kind'] as String? ?? '';
      if (typeFilter == 'listen' && kind != 'listen' ||
          typeFilter == 'events' && kind == 'listen') {
        return false;
      }
      return _matchesEntry(data, _eventName(kind));
    }).toList();
    if (!newestFirst) return result.reversed.toList();
    return result;
  }

  List<LibraryRecord> _visibleLegacy() {
    if (typeFilter != 'all' && typeFilter != 'legacy') return [];
    final result = legacyListening
        .where((entry) => _matchesEntry(entry.payload ?? {}, 'старая сессия'))
        .toList();
    if (!newestFirst) return result.reversed.toList();
    return result;
  }

  List<({LibraryRecord record, bool legacy})> _visibleAudioRows() {
    final rows = <({LibraryRecord record, bool legacy})>[
      for (final record in _visibleAudioEvents())
        (record: record, legacy: false),
      for (final record in _visibleLegacy()) (record: record, legacy: true),
    ];
    rows.sort((a, b) {
      final order = _dateOf(a.record.payload ?? {})
          .compareTo(_dateOf(b.record.payload ?? {}));
      return newestFirst ? -order : order;
    });
    return rows;
  }

  int _readingMilliseconds(_ReadingEntry entry) => entry.automatic
      ? (entry.payload['spans'] as List? ?? const []).fold<int>(
          0,
          (sum, raw) =>
              sum + (((raw as Map)['activeMs'] as num?)?.toInt() ?? 0),
        )
      : ((entry.payload['activeSeconds'] as num?)?.toInt() ?? 0) * 1000;

  int _readingCharacters(_ReadingEntry entry) => entry.automatic
      ? (entry.payload['spans'] as List? ?? const []).fold<int>(
          0,
          (sum, raw) =>
              sum +
              (((raw as Map)['newChars'] as num?)?.toInt() ?? 0) +
              ((raw['repeatChars'] as num?)?.toInt() ?? 0),
        )
      : ((entry.payload['newChars'] as num?)?.toInt() ?? 0) +
            ((entry.payload['repeatChars'] as num?)?.toInt() ?? 0);

  Widget _filters() {
    final isReading = tabs.index == 0;
    final books = isReading ? readingBooks : audioBooks;
    final count = isReading
        ? _visibleReading().length
        : _visibleAudioRows().length;
    final time = isReading
        ? _visibleReading().fold<int>(
            0,
            (sum, entry) => sum + _readingMilliseconds(entry),
          )
        : _visibleAudioEvents().fold<int>(
                0,
                (sum, entry) =>
                    sum +
                    (entry.payload?['kind'] == 'listen'
                        ? ((entry.payload?['wallMs'] as num?)?.toInt() ?? 0)
                        : 0),
              ) +
              _visibleLegacy().fold<int>(
                0,
                (sum, entry) =>
                    sum +
                    ((entry.payload?['activeSeconds'] as num?)?.toInt() ?? 0) *
                        1000,
              );
    final kinds = isReading
        ? const {'all': 'Все записи', 'automatic': 'Авто', 'manual': 'Ручные'}
        : const {
            'all': 'Все записи',
            'listen': 'Прослушивание',
            'events': 'События',
            'legacy': 'Старые сессии',
          };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Поиск по книге, дате или типу записи',
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить поиск',
                      onPressed: () => setState(search.clear),
                      icon: const Icon(Icons.close),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                DropdownButton<String?>(
                  value: selectedBookId,
                  hint: const Text('Все книги'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Все книги'),
                    ),
                    for (final book in books)
                      DropdownMenuItem<String?>(
                        value: book.id,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            book.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => selectedBookId = value),
                ),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: typeFilter,
                  items: [
                    for (final entry in kinds.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => typeFilter = value ?? 'all'),
                ),
                const SizedBox(width: 10),
                DropdownButton<int>(
                  value: periodDays,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Всё время')),
                    DropdownMenuItem(value: 7, child: Text('7 дней')),
                    DropdownMenuItem(value: 30, child: Text('30 дней')),
                    DropdownMenuItem(value: 365, child: Text('Год')),
                  ],
                  onChanged: (value) => setState(() => periodDays = value ?? 0),
                ),
                IconButton(
                  tooltip: newestFirst ? 'Сначала старые' : 'Сначала новые',
                  onPressed: () => setState(() => newestFirst = !newestFirst),
                  icon: Icon(
                    newestFirst ? Icons.arrow_downward : Icons.arrow_upward,
                  ),
                ),
              ],
            ),
          ),
          Text(
            isReading
                ? 'Показано: $count · ${_durationLabel(time)} · ${_visibleReading().fold<int>(0, (sum, entry) => sum + _readingCharacters(entry))} знаков'
                : 'Показано: $count · ${_durationLabel(time)}',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }

  Future<void> _copyVisibleCsv({bool selectedOnly = false}) async {
    String cell(Object? value) => '"${'$value'.replaceAll('"', '""')}"';
    final lines = <String>['тип,книга,дата,секунды,знаки,id'];
    if (tabs.index == 0) {
      for (final entry
          in selectedOnly
              ? reading.where(
                  (entry) => selectedEntries.contains('reading:${entry.id}'),
                )
              : _visibleReading()) {
        lines.add(
          [
            entry.automatic ? 'Авто' : 'Ручная',
            titles[entry.payload['bookId']] ?? '',
            _dateLabel(entry.payload['startedAt']),
            _readingMilliseconds(entry) ~/ 1000,
            _readingCharacters(entry),
            entry.id,
          ].map(cell).join(','),
        );
      }
    } else {
      for (final row
          in selectedOnly
              ? [
                  for (final record in audioEvents)
                    if (selectedEntries.contains('audio:${record.id}'))
                      (record: record, legacy: false),
                  for (final record in legacyListening)
                    if (selectedEntries.contains('legacy:${record.id}'))
                      (record: record, legacy: true),
                ]
              : _visibleAudioRows()) {
        final entry = row.record;
        final data = entry.payload ?? {};
        lines.add(
          [
            row.legacy
                ? 'Старая сессия'
                : _eventName(data['kind'] as String? ?? ''),
            titles[data['bookId']] ?? '',
            _dateLabel(data['startedAt'] ?? data['at']),
            row.legacy
                ? (data['activeSeconds'] as num?)?.toInt() ?? 0
                : data['kind'] == 'listen'
                ? ((data['wallMs'] as num?)?.toInt() ?? 0) ~/ 1000
                : 0,
            0,
            entry.id,
          ].map(cell).join(','),
        );
      }
    }
    final csv = '\uFEFF${lines.join('\r\n')}';
    if (csv.length > 4 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Выберите меньший период для копирования.'),
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Скопировано записей: ${lines.length - 1}')),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: const AudioPlayerFooter(),
    appBar: AppBar(
      title: Text(
        selectedEntries.isEmpty
            ? 'Управление статистикой'
            : 'Выбрано: ${selectedEntries.length}',
      ),
      bottom: TabBar(
        controller: tabs,
        tabs: const [
          Tab(icon: Icon(Icons.menu_book_outlined), text: 'Чтение'),
          Tab(icon: Icon(Icons.headphones_outlined), text: 'Прослушивание'),
        ],
      ),
      actions: selectedEntries.isNotEmpty
          ? [
              IconButton(
                tooltip: 'Выбрать все видимые',
                onPressed: () =>
                    setState(() => selectedEntries.addAll(_visibleKeys())),
                icon: const Icon(Icons.select_all),
              ),
              IconButton(
                tooltip: 'Удалить выбранные',
                onPressed: _deleteSelected,
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: 'Скопировать выбранные в CSV',
                onPressed: () => _copyVisibleCsv(selectedOnly: true),
                icon: const Icon(Icons.table_view_outlined),
              ),
              IconButton(
                tooltip: 'Отменить выбор',
                onPressed: () => setState(selectedEntries.clear),
                icon: const Icon(Icons.close),
              ),
            ]
          : [
              IconButton(
                tooltip: 'Выбрать видимые записи',
                onPressed: loading
                    ? null
                    : () => setState(
                        () => selectedEntries.addAll(_visibleKeys()),
                      ),
                icon: const Icon(Icons.select_all),
              ),
              IconButton(
                tooltip: 'Скопировать видимые записи в CSV',
                onPressed: loading ? null : _copyVisibleCsv,
                icon: const Icon(Icons.table_view_outlined),
              ),
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
              _filters(),
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
      : Builder(
          builder: (context) {
            final visible = _visibleReading();
            return visible.isEmpty
                ? const Center(
                    child: Text('По выбранным фильтрам записей нет.'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: visible.length,
                    itemBuilder: (_, index) => _readingItem(visible[index]),
                  );
          },
        );

  Widget _audioList() => audioEvents.isEmpty && legacyListening.isEmpty
      ? const Center(
          child: Text(
            'Событий прослушивания пока нет. Добавьте запись вручную.',
          ),
        )
      : Builder(
          builder: (context) {
            final rows = _visibleAudioRows();
            if (rows.isEmpty) {
              return const Center(
                child: Text('По выбранным фильтрам записей нет.'),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: rows.length,
              itemBuilder: (_, index) => rows[index].legacy
                  ? _legacyItem(rows[index].record)
                  : _audioItem(rows[index].record),
            );
          },
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
  DateTime? initialStart,
  String submitLabel = 'Добавить',
}) async {
  String bookId = initialBookId;
  DateTime start =
      initialStart ??
      DateTime.now().subtract(Duration(minutes: initialMinutes));
  var minutes = '$initialMinutes';
  String? error;
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
                  onChanged: (value) => setState(() {
                    minutes = value;
                    error = null;
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
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final duration = int.tryParse(minutes);
              if (duration == null || duration < 1 || duration > 1440) {
                setState(() => error = 'Укажите от 1 до 1440 минут.');
                return;
              }
              Navigator.pop(
                context,
                _ManualSessionValue(bookId, start, duration),
              );
            },
            child: Text(submitLabel),
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
                              !next.any((e) => e.key == trackId)) {
                            trackId = next.first.key;
                          }
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
