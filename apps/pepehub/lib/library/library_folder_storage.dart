import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:path/path.dart' as p;

import '../data/repository.dart' show uuid;
import '../storage/folder_files.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'library_features.dart';
import 'library_service.dart';
import 'models.dart';
import 'note_store.dart';
import 'personal_library.dart';
import '../diagnostics/user_message.dart';

const _folderKey = 'library-storage-folder-v1';
const _baselineKey = 'library-storage-baseline-v1';
const _layoutKey = 'library-storage-layout-v1';

/// Base of this device's unconfirmed writes: see [LibraryFolderStorage].
const _chainKey = 'library-storage-chain-v1';
const _cleanupKey = 'library-storage-cleanup-v1';
const _prefix = 'PepeHub-library/';
const _manifestPath = '${_prefix}library.json';
const _bookFilesPath = '${_prefix}objects/book-files.json';
const _beforeNamedBooks = '${_prefix}objects/library-before-named-books.json';

/// Digests of earlier catalogs kept in each catalog. A device whose last
/// write is missing from this list knows that write was lost (for example
/// renamed by Syncthing to a conflict copy) and merges against an older base.
const _maxAncestors = 128;

/// Unreferenced objects and covers are removed after this long.
const libraryFolderCleanupAge = Duration(days: 30);
const _folderReadme = '''# PepeHub Library

Книги/ — файлы с названиями произведений, разложенные по сериям.
Корзина/ — файлы удалённых карточек, пока они хранятся в корзине.
library.json и objects/ — служебный каталог и версии данных для обмена.
covers/<SHA-256>.png — сохранённые обложки.

Именованные JSON-файлы содержат карточку, заметки и историю. Изменяйте данные в PepeHub.
Синхронизируйте всю папку PepeHub-library. Исходные книги и аудио хранятся отдельно.
Служебные версии, на которые больше не ссылается каталог, удаляются через 30 дней.

Syncthing: добавьте в игнорируемые шаблоны строку .pepehub* на каждом устройстве —
так называются временные файлы записи. Копии *.sync-conflict-* не нужны: изменения
обоих устройств PepeHub объединяет сам, а копии можно удалить на вкладке «Данные».
''';
const _releasedFolderReadme = '''# PepeHub Library

Книги/ — файлы с названиями произведений, разложенные по сериям.
Корзина/ — файлы удалённых карточек, пока они хранятся в корзине.
library.json и objects/ — служебный каталог и версии данных для обмена.
covers/<SHA-256>.png — сохранённые обложки.

Именованные JSON-файлы содержат карточку, заметки и историю. Изменяйте данные в PepeHub.
Синхронизируйте всю папку PepeHub-library. Исходные книги и аудио хранятся отдельно.
Служебные версии, на которые больше не ссылается каталог, удаляются через 30 дней.

Syncthing: добавьте в игнорируемые шаблоны строку .pepehub на каждом устройстве —
там лежат временные файлы записи. Копии *.sync-conflict-* не нужны: изменения
обоих устройств PepeHub объединяет сам, а копии можно удалить на вкладке «Данные».
''';
const _previousFolderReadme = '''# PepeHub Library

Книги/ — файлы с названиями произведений, разложенные по сериям.
Корзина/ — файлы удалённых карточек, пока они хранятся в корзине.
library.json и objects/ — служебный каталог и версии данных для обмена.
covers/<SHA-256>.png — сохранённые обложки.

Именованные JSON-файлы содержат карточку, заметки и историю. Изменяйте данные в PepeHub.
Синхронизируйте всю папку PepeHub-library. Исходные книги и аудио хранятся отдельно.
Служебные версии сохраняются для восстановления и обмена.
''';
const _legacyFolderReadme = '''# PepeHub Library

library.json — каталог переносимой личной библиотеки (формат 1).
objects/xx/<SHA-256>.json — неизменяемые карточки, история, цитаты и настройки.
covers/<SHA-256>.png — сохранённые обложки.

Синхронизируйте всю папку PepeHub-library. Файлы книг и аудио хранятся отдельно.
Не удаляйте объекты вручную: они могут понадобиться другим устройствам.
Перед ручным редактированием или разрешением конфликтов сохраните копию папки.
''';
const _settingsPrefixes = [
  'library-series-length:',
  'library-year-goal:personal:',
  'obsidian-policy:personal:',
  'library-trash-retention-days',
];
bool _portableSetting(String key) =>
    key == 'library-trash-retention-days' ||
    _settingsPrefixes.take(3).any(key.startsWith);
final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
  caseSensitive: false,
);
final _hash = RegExp(r'^[a-f0-9]{64}$');

dynamic _ordered(dynamic value) => value is Map
    ? {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: _ordered(value[key]),
      }
    : value is List
    ? value.map(_ordered).toList()
    : value;
String _encode(dynamic value) => jsonEncode(_ordered(value));
String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
String _objectPath(String hash) =>
    '${_prefix}objects/${hash.substring(0, 2)}/$hash.json';
String _coverPath(String hash) => '${_prefix}covers/$hash.png';
Future<T> _folderWork<T, P>(T Function(P) task, P input) =>
    Isolate.run(() => task(input));
Map<String, String> _snapshot(
  (Map<String, dynamic>, String, String, Map<String, String>) input,
) => _documents(input.$1, input.$2, input.$3, input.$4);
Map<String, String> _hashDocuments(Map<String, String> documents) =>
    documents.map((key, raw) => MapEntry(key, _digest(raw)));

String _fileName(String title, String fallback) {
  final clean = title
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final shortened = StringBuffer();
  var bytes = 0;
  for (final rune in clean.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > 175) break;
    shortened.write(character);
  }
  final name = shortened.toString().replaceAll(RegExp(r'^\.+|[. ]+$'), '');
  if (name.isEmpty) return fallback;
  try {
    return folderPath(name);
  } on FormatException {
    return '_$name';
  }
}

String _uniqueName(String base, String suffix, Set<String> used) {
  var name = base;
  var attempt = 1;
  while (!used.add(name.toLowerCase())) {
    name = '$base [$suffix${attempt == 1 ? '' : '-$attempt'}]';
    attempt++;
  }
  return name;
}

Map<String, ({String id, String raw})> _namedBooks(Map<String, dynamic> data) {
  final items = [
    for (final key
        in data.keys.where((key) => key.startsWith('cards/')).toList()..sort())
      LibraryItem.fromJson(data[key]),
  ];
  final seriesNames = <String, String>{};
  // Names are unique per parent: «Книги/Серия» and «Корзина/Серия» coexist.
  final usedSeries = <String, Set<String>>{};
  final usedPaths = <String>{};
  final books = <String, ({String id, String raw})>{};
  for (final item in items) {
    final series = '${item.value('series') ?? ''}'.trim();
    var directory = isLibraryDeleted(item) ? 'Корзина' : 'Книги';
    if (series.isNotEmpty) {
      final key = librarySeriesKey(item);
      final parent = directory;
      final name = seriesNames.putIfAbsent(
        '$parent\u0000$key',
        () => _uniqueName(
          _fileName(series, 'Серия'),
          _digest(key).substring(0, 12),
          usedSeries.putIfAbsent(parent, () => <String>{}),
        ),
      );
      directory += '/$name';
    }
    final title = _fileName(item.title, 'Без названия');
    final path = '${_uniqueName('$directory/$title', item.id, usedPaths)}.json';
    final document = _ordered({
      'format': 'pepehub-book',
      'version': 1,
      'card': data['cards/${item.id}'],
      'history': data['history/${item.id}'] ?? <String, dynamic>{},
      'notes': data['notes/${item.id}'] ?? <String, dynamic>{},
    });
    books[path] = (
      id: item.id,
      raw: '${const JsonEncoder.withIndent('  ').convert(document)}\n',
    );
  }
  return books;
}

/// Only portable values go into the folder. Native links, queues and credentials
/// belong to this device's database and survive reconnecting the same archive.
Map<String, String> _documents(
  Map<String, dynamic> cards,
  String history,
  String notes,
  Map<String, String> settings,
) {
  final result = {
    for (final e in cards.entries) 'cards/${e.key}': _encode(e.value),
  };
  for (final pair in [('history', history), ('notes', notes)]) {
    final groups = <String, Map<String, dynamic>>{};
    for (final slot in (jsonDecode(pair.$2)['slots'] as Map).values) {
      final value = slot['value'] as Map;
      final item = value['itemId'] as String;
      if (cards.containsKey(item)) {
        (groups[item] ??= {})[value['id'] as String] = value;
      }
    }
    for (final e in groups.entries) {
      result['${pair.$1}/${e.key}'] = _encode(e.value);
    }
  }
  if (settings.isNotEmpty) result['settings'] = _encode(settings);
  return result;
}

/// Three-way merge of one work's history or notes, entry by entry.
///
/// Entries have stable IDs and deletions are tombstones, so an entry present
/// on one side only is kept. When both sides changed the same entry, a note
/// keeps the later `updatedAt`, a session keeps a deletion or else the longer
/// duration. Sessions and notes recorded on two devices therefore never
/// replace each other, and no conflict has to be resolved by hand.
String mergeLibraryJournal(
  String kind,
  String here,
  String there, [
  String? base,
]) {
  Map<String, dynamic> decode(String raw) =>
      Map<String, dynamic>.from(jsonDecode(raw) as Map);
  final mine = decode(here), theirs = decode(there);
  final before = base == null ? const <String, dynamic>{} : decode(base);
  bool same(Object? a, Object? b) => _encode(a) == _encode(b);
  final result = <String, dynamic>{};
  for (final id in {...mine.keys, ...theirs.keys}) {
    final h = mine[id], t = theirs[id], b = before[id];
    if (h == null || t == null || same(h, t)) {
      result[id] = h ?? t;
    } else if (b != null && same(h, b)) {
      result[id] = t;
    } else if (b != null && same(t, b)) {
      result[id] = h;
    } else if (kind == 'notes') {
      result[id] = '${t['updatedAt']}'.compareTo('${h['updatedAt']}') > 0
          ? t
          : h;
    } else if ((t['deleted'] == true) != (h['deleted'] == true)) {
      result[id] = t['deleted'] == true ? t : h;
    } else {
      final mineMs = (h['durationMs'] as num?) ?? 0,
          theirMs = (t['durationMs'] as num?) ?? 0;
      result[id] = theirMs > mineMs ? t : h;
    }
  }
  return _encode(result);
}

/// The folder is still receiving files from another device.
class LibraryFolderPending implements Exception {
  final String message;
  const LibraryFolderPending(this.message);
  @override
  String toString() => message;
}

/// What the folder holds; filled after each successful update.
class LibraryFolderStats {
  final int cards, deleted, history, notes, covers;
  const LibraryFolderStats({
    required this.cards,
    required this.deleted,
    required this.history,
    required this.notes,
    required this.covers,
  });
}

/// Files of a folder on this computer, inspected for the «Данные» screen.
class LibraryFolderReport {
  final int objects, unusedObjects, unusedCovers, unusedBytes;

  /// `*.sync-conflict-*` copies inside PepeHub-library, relative paths.
  final List<String> conflictCopies;

  /// Directory with `.stfolder`, when the library is inside a Syncthing folder.
  final String? syncthingRoot;

  /// `.stignore` of [syncthingRoot] excludes PepeHub temporary files.
  final bool ignoresTemporary;
  const LibraryFolderReport({
    required this.objects,
    required this.unusedObjects,
    required this.unusedCovers,
    required this.unusedBytes,
    required this.conflictCopies,
    required this.syncthingRoot,
    required this.ignoresTemporary,
  });
}

/// `.pepehub*` covers the `.pepehub` folder and the `.pepehub-transfer-*` /
/// `.pepehub-rollback-*` files Android leaves next to the file it replaces.
const syncthingIgnorePattern = '.pepehub*';

bool _ignoresPepeHub(String stignore) => const LineSplitter()
    .convert(stignore)
    .map((line) => line.trim().replaceFirst(RegExp(r'^(\(\?[di]\))+'), ''))
    .any((line) => const {'.pepehub*', '**/.pepehub*'}.contains(line));

enum LibraryFolderPreference { local, folder }

class LibraryFolderConflict implements Exception {
  final List<String> documents;
  const LibraryFolderConflict(this.documents);
  @override
  String toString() =>
      'Одни и те же записи изменены по-разному здесь и в папке '
      '(${documents.length}). Выберите версию в разделе «Экспорт и резервные копии».';
}

class _Manifest {
  final String id;
  final Map<String, String> documents;
  final Set<String> covers;

  /// Digests of the catalogs this one was built on, newest first. Empty in
  /// catalogs written by older versions.
  final List<String> ancestors;
  const _Manifest(
    this.id,
    this.documents,
    this.covers, [
    this.ancestors = const [],
  ]);
  Map<String, dynamic> toJson() => {
    'format': 'pepehub-library-folder',
    'version': 2,
    'id': id,
    'documents': documents,
    'covers': covers.toList()..sort(),
    if (ancestors.isNotEmpty) 'ancestors': ancestors,
  };
  factory _Manifest.read(String raw) {
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['format'] != 'pepehub-library-folder' ||
        ![1, 2].contains(data['version']) ||
        data['id'] is! String ||
        !_uuid.hasMatch(data['id']) ||
        data['documents'] is! Map ||
        (data['documents'] as Map).length > 150001 ||
        data['covers'] is! List ||
        (data['covers'] as List).length > 50000) {
      throw const FormatException('Неизвестный формат папки библиотеки');
    }
    final documents = Map<String, String>.from(data['documents'] as Map);
    for (final e in documents.entries) {
      final parts = e.key.split('/');
      if (!_hash.hasMatch(e.value) ||
          e.key != 'settings' &&
              (parts.length != 2 ||
                  !['cards', 'history', 'notes'].contains(parts[0]) ||
                  !_uuid.hasMatch(parts[1]))) {
        throw const FormatException('Повреждён каталог библиотеки');
      }
    }
    final covers = (data['covers'] as List).cast<String>().toSet();
    if (covers.any((hash) => !_hash.hasMatch(hash))) {
      throw const FormatException('Повреждён список обложек');
    }
    final ancestors = data['ancestors'] ?? const [];
    if (ancestors is! List ||
        ancestors.length > _maxAncestors ||
        ancestors.any((hash) => hash is! String || !_hash.hasMatch(hash))) {
      throw const FormatException('Повреждена история каталога');
    }
    return _Manifest(data['id'], documents, covers, ancestors.cast<String>());
  }
}

/// This device's writes since it last read a catalog written elsewhere.
/// [base] is that catalog. If the newest write is later lost, the catalog
/// in the folder no longer lists it among its ancestors and [base] becomes
/// the common version for the three-way merge.
class _Chain {
  final String? base;
  final List<String> own;
  const _Chain(this.base, this.own);
  static _Chain read(String? raw) {
    if (raw == null) return const _Chain(null, []);
    final data = jsonDecode(raw) as Map;
    return _Chain(
      data['base'] as String?,
      (data['own'] as List).cast<String>(),
    );
  }

  String encode() => jsonEncode({'base': base, 'own': own});
}

class _FolderFiles {
  final FolderFileSystem files;
  final bool direct;
  const _FolderFiles(this.files, {required this.direct});
  String _path(String path) => direct ? path.substring(_prefix.length) : path;
  Future<String?> hash(String path) => files.hash(_path(path));

  /// Size and modification time without reading; null when unsupported.
  Future<String?> stamp(String path) async => switch (files) {
    final LocalFolderFiles local => local.stamp(_path(path)),
    final SafFolderFiles saf => saf.stamp(_path(path)),
    _ => null,
  };
  Future<List<int>> read(String path, int offset, int count) =>
      files.read(_path(path), offset, count);
  Future<FolderStagingFile> stage(FolderFileEntry entry) =>
      files.stage(entry.withClock(entry.clock, path: _path(entry.path)));
  Future<void> remove(String path, String expected) =>
      files.remove(_path(path), expected);

  /// PepeHub-library on this computer; null for Android folders, which
  /// cannot be listed cheaply.
  Directory? get localLibrary => switch (files) {
    final LocalFolderFiles local =>
      direct
          ? local.root
          : Directory(p.join(local.root.path, 'PepeHub-library')),
    _ => null,
  };

  /// The selected folder on this computer.
  Directory? get localRoot => switch (files) {
    final LocalFolderFiles local => local.root,
    _ => null,
  };
}

class _LibraryChangedDuringSave implements Exception {}

/// A portable folder is the durable exchange format; SQLite is a transactional
/// working cache. Immutable objects are published before the small manifest.
/// A persisted three-way baseline also protects edits pending after a crash.
class LibraryFolderStorage extends ChangeNotifier {
  final LibraryService library;
  final FolderFileSystem Function(String) _fileSystem;
  LibraryFolderStorage(
    this.library, {
    FolderFileSystem Function(String)? fileSystem,
  }) : _fileSystem = fileSystem ?? folderFileSystem;
  String? folder;
  String? error;
  String? warning;

  /// Another device's files are still arriving; the next check retries.
  String? pending;

  /// Last write to the folder and last successful check of it.
  DateTime? savedAt, checkedAt;
  LibraryFolderStats? stats;
  bool working = false, _disposed = false;

  /// Journal-only changes (reading and listening sessions) are written at most
  /// this often while the app is open, and right away when it is hidden.
  static const journalDelay = Duration(minutes: 2);
  AppLifecycleListener? _lifecycle;
  DateTime? _lastCleanup;
  static const _cleanupEvery = Duration(hours: 6);
  Future<void>? _initialized;
  Future<void> _tail = Future.value();
  Timer? _timer;
  String? _lastRevision, _lastManifest;

  /// Manifest stamp observed right before a read that matched [_lastManifest].
  String? _lastManifestStamp;
  DateTime? _lastFullCheck;

  /// Even with an unchanged stamp the manifest is reread this often, in case
  /// a sync tool preserved size and modification time of a changed file.
  static const _fullCheckEvery = Duration(minutes: 2);
  bool _direct = false;
  bool get enabled => folder != null;
  String? get displayPath => folder == null
      ? null
      : _direct
      ? folder
      : '${folder!}/PepeHub-library';

  Future<void> initialize() {
    if (_disposed) {
      return Future.error(StateError('Хранилище библиотеки закрыто'));
    }
    return _initialized ??= _initialize().onError((
      Object error,
      StackTrace stack,
    ) {
      _initialized = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _initialize() async {
    folder = await library.local.meta(_folderKey);
    _direct = await library.local.meta(_layoutKey) == 'root';
    if (folder != null) await _tracking();
    _startTimer();
  }

  void _startTimer() {
    if (!_disposed && enabled && _timer == null) {
      // Polls are cheap (a stat call) unless the manifest changed.
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (enabled && !working) {
          unawaited(
            synchronize()
                .then((changed) async {
                  if (changed && !_disposed) await library.loadCached();
                })
                .catchError((Object _) {}),
          );
        }
      });
    }
    if (!_disposed && enabled && _lifecycle == null) {
      try {
        _lifecycle = AppLifecycleListener(onHide: _flushInBackground);
      } on Object catch (e) {
        // No widgets binding (command-line use): polling still saves.
        debugPrint('Library folder lifecycle unavailable: $e');
      }
    }
  }

  void _flushInBackground() {
    if (!enabled || _disposed) return;
    unawaited(flush().then((_) {}, onError: (Object _) {}));
  }

  /// Writes pending journal changes now instead of after [journalDelay].
  Future<bool> flush() async {
    await initialize();
    return _serial(() async {
      if (_disposed || folder == null) return false;
      return _synchronize(folder!, deferJournal: false);
    });
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  /// Triggers observe committed SQL changes, including deletes and writes from
  /// other Repository instances. Polling an unchanged archive reads one row.
  Future<void> _tracking() async {
    final db = library.local.db;
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS library_folder_revision_v1 '
      '(id INTEGER PRIMARY KEY,revision INTEGER NOT NULL,native INTEGER NOT NULL)',
    );
    await db.customStatement(
      'INSERT OR IGNORE INTO library_folder_revision_v1 VALUES(1,0,0)',
    );
    for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
      final row = event == 'DELETE' ? 'OLD' : 'NEW';
      final changed = event == 'UPDATE' ? 'AND OLD.value IS NOT NEW.value' : '';
      final native =
          "($row.key LIKE 'reading-note:%' OR $row.key LIKE 'reading-session:%')";
      final portable = [
        "$row.key='$personalLibraryKey'",
        "$row.key='obsidian-activity:personal'",
        "$row.key='obsidian-notes:personal'",
        for (final prefix in _settingsPrefixes) "$row.key LIKE '$prefix%'",
      ].join(' OR ');
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS library_folder_meta_${event.toLowerCase()}_v1 '
        'AFTER $event ON metadata WHEN ($portable OR $native) $changed BEGIN '
        'UPDATE library_folder_revision_v1 SET revision=revision+1,native=native+CASE WHEN $native THEN 1 ELSE 0 END WHERE id=1; END',
      );
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS library_folder_records_${event.toLowerCase()}_v1 '
        "AFTER $event ON records WHEN $row.type IN ('session','audio_event','audio_note') BEGIN "
        'UPDATE library_folder_revision_v1 SET revision=revision+1,native=native+1 WHERE id=1; END',
      );
    }
  }

  Future<String> _revision() async {
    final row = await library.local.db
        .customSelect(
          'SELECT revision,native FROM library_folder_revision_v1 WHERE id=1',
        )
        .getSingle();
    return '${row.read<int>('revision')}:${row.read<int>('native')}';
  }

  /// Connection merges distinct works; overwriting a concurrent edit requires
  /// an explicit preference. The UI saves a ZIP before resolving conflicts.
  Future<void> connect(
    String selected, {
    LibraryFolderPreference? preference,
  }) async {
    await initialize();
    if (!selected.startsWith('content://')) {
      selected = p.normalize(p.absolute(selected));
    }
    await _serial(() async {
      warning = null;
      String? previousWarning;
      if (folder != null && selected != folder) {
        try {
          await _synchronize(folder!, force: true);
        } catch (_) {
          previousWarning =
              'Не удалось записать предыдущую папку. '
              'Текущая библиотека перенесена из локальной копии.';
        }
      }
      await _tracking();
      await _synchronize(selected, connecting: true, preference: preference);
      folder = selected;
      warning = previousWarning;
      _startTimer();
      _status();
    });
    await library.loadCached();
  }

  Future<bool> disconnect() async {
    await initialize();
    return _serial(() async {
      var saved = true;
      if (folder != null) {
        try {
          await _synchronize(folder!, force: true);
        } catch (_) {
          saved = false;
        }
      }
      // A disconnected/missing disk must not prevent keeping the working copy.
      await library.local.db.transaction(() async {
        await library.local.db.customStatement(
          'DELETE FROM metadata WHERE key IN (?,?,?,?,?)',
          [_folderKey, _baselineKey, _layoutKey, _chainKey, _cleanupKey],
        );
      });
      folder = null;
      _timer?.cancel();
      _timer = null;
      _lifecycle?.dispose();
      _lifecycle = null;
      error = null;
      warning = null;
      pending = null;
      stats = null;
      savedAt = checkedAt = null;
      _direct = false;
      _lastRevision = _lastManifest = _lastManifestStamp = null;
      _status();
      return saved;
    });
  }

  Future<bool> synchronize({
    bool force = false,
    LibraryFolderPreference? preference,
  }) async {
    await initialize();
    return _serial(() async {
      if (_disposed || folder == null) return false;
      return _synchronize(folder!, force: force, preference: preference);
    });
  }

  Future<Uint8List?> _read(_FolderFiles fs, String path, int limit) async {
    final expected = await fs.hash(path);
    if (expected == null) return null;
    final bytes = BytesBuilder(copy: false);
    var offset = 0;
    while (true) {
      final chunk = await fs.read(path, offset, folderChunkSize);
      bytes.add(chunk);
      offset += chunk.length;
      if (offset > limit) {
        throw FormatException('Слишком большой файл библиотеки: $path');
      }
      if (chunk.length < folderChunkSize) break;
    }
    final result = bytes.takeBytes();
    if (sha256.convert(result).toString() != expected) {
      throw LibraryFolderPending('Файл ещё синхронизируется: $path');
    }
    return result;
  }

  /// Android replaces library.json by renaming the old file aside and the new
  /// one into place. When Syncthing copies the folder between those renames,
  /// this computer receives the leftovers (`.pepehub-rollback-*`,
  /// `.pepehub-transfer-*.part`) and no library.json. Put the newest complete
  /// catalog back; the regular merge then handles it like any other version.
  Future<bool> _restoreManifest(_FolderFiles fs) async {
    final dir = fs.localLibrary;
    if (dir == null || await fs.stamp(_manifestPath) != 'missing') return false;
    if (!await dir.exists()) return false;
    final saved = await library.local.meta(_baselineKey);
    final id = saved == null ? null : _Manifest.read(saved).id;
    final found = <String, ({String raw, _Manifest manifest})>{};
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final transfer = RegExp(
        r'^\.pepehub-transfer-[a-f0-9]{64}-([a-f0-9]{64})\.part$',
      ).firstMatch(name);
      final rollback =
          name.startsWith('.pepehub-rollback-') &&
          name.endsWith('-library.json');
      if (transfer == null && !rollback) continue;
      if (await entry.length() > 16777216) continue;
      final bytes = await entry.readAsBytes();
      final digest = sha256.convert(bytes).toString();
      // An unfinished transfer is named after the content it expects.
      if (transfer != null && transfer.group(1) != digest) continue;
      try {
        final raw = utf8.decode(bytes);
        final manifest = _Manifest.read(raw);
        if (id != null && manifest.id != id) continue;
        var complete = true;
        for (final hash in manifest.documents.values.toSet()) {
          final object = p.join(
            dir.path,
            'objects',
            hash.substring(0, 2),
            '$hash.json',
          );
          if (!await File(object).exists()) {
            complete = false;
            break;
          }
        }
        if (complete) found[digest] = (raw: raw, manifest: manifest);
      } catch (_) {
        // Not a catalog, or damaged: ignore.
      }
    }
    final newest = [
      for (final e in found.entries)
        if (!found.values.any((o) => o.manifest.ancestors.contains(e.key)))
          e.value,
    ];
    if (newest.length != 1 || await fs.stamp(_manifestPath) != 'missing') {
      return false;
    }
    await _write(fs, _manifestPath, utf8.encode(newest.single.raw), null);
    return true;
  }

  Future<void> _write(
    _FolderFiles fs,
    String path,
    List<int> bytes,
    String? expected,
  ) async {
    final stage = await fs.stage(
      FolderFileEntry(
        path: path,
        hash: sha256.convert(bytes).toString(),
        bytes: bytes.length,
        clock: const {'00000000-0000-4000-8000-000000000001': 1},
      ),
    );
    try {
      await stage.prepare();
      await stage.reset();
      for (var at = 0; at < bytes.length; at += folderChunkSize) {
        await stage.append(
          at,
          bytes.sublist(at, (at + folderChunkSize).clamp(0, bytes.length)),
        );
      }
      await stage.publish(expected);
    } finally {
      await stage.discard();
    }
  }

  Future<bool> _synchronize(
    String selected, {
    bool force = false,
    bool connecting = false,
    LibraryFolderPreference? preference,
    bool deferJournal = true,
    int attempt = 0,
  }) async {
    if (_disposed) throw StateError('Хранилище библиотеки закрыто');
    working = true;
    try {
      final files = _fileSystem(selected);
      await files.checkRoot();
      var direct = _direct;
      if (connecting) {
        final rootManifest = await files.hash('library.json');
        final nestedManifest = await files.hash(_manifestPath);
        if (rootManifest != null && nestedManifest != null) {
          throw StateError(
            'В выбранной папке найдены две библиотеки. '
            'Выберите нужную папку PepeHub-library отдельно.',
          );
        }
        final name = selected.startsWith('content://')
            ? p.posix
                  .basename(
                    Uri.decodeComponent(Uri.parse(selected).pathSegments.last),
                  )
                  .split(':')
                  .last
            : p.basename(selected);
        direct =
            rootManifest != null ||
            nestedManifest == null && name.toLowerCase() == 'pepehub-library';
      }
      final fs = _FolderFiles(files, direct: direct);
      final quick = !connecting && !force;
      // Taken before reading: a write after this point changes the stamp.
      final stamp = quick ? await fs.stamp(_manifestPath) : null;
      final lastFull = _lastFullCheck;
      final now = DateTime.now();
      final unchanged =
          quick &&
          stamp != null &&
          stamp == _lastManifestStamp &&
          lastFull != null &&
          now.difference(lastFull) < _fullCheckEvery;
      if (unchanged) {
        final current = await _revision();
        // Session checkpoints arrive every 30 s while reading; writing a new
        // catalog for each one only makes the sync tool busy.
        final deferred =
            deferJournal &&
            _onlyJournal(current, _lastRevision) &&
            savedAt != null &&
            now.difference(savedAt!) < journalDelay;
        if (current == _lastRevision || deferred) {
          _clearProblems();
          return false;
        }
      }
      if (!connecting && await _restoreManifest(fs)) _lastManifestStamp = null;
      final manifestBytes = await _read(fs, _manifestPath, 16777216);
      final raw = manifestBytes == null ? null : utf8.decode(manifestBytes);
      var revision = await _revision();
      if (quick && revision == _lastRevision && raw == _lastManifest) {
        _lastManifestStamp = stamp;
        _lastFullCheck = now;
        checkedAt = now;
        _clearProblems();
        return false;
      }
      _lastManifestStamp = null;
      final remote = raw == null ? null : _Manifest.read(raw);
      final saved = await library.local.meta(_baselineKey);
      final previous = saved == null ? null : _Manifest.read(saved);
      final chain = connecting
          ? const _Chain(null, [])
          : _Chain.read(await library.local.meta(_chainKey));
      var baseline = !connecting || remote != null && previous?.id == remote.id
          ? previous
          : null;
      // Our newest write may have been replaced in the folder (Syncthing keeps
      // the other device's file and renames ours to a conflict copy). Then
      // our saved version is not an ancestor of the folder's catalog and
      // "unchanged here" would silently revert our own edits.
      var lostBase = false;
      if (!connecting &&
          remote != null &&
          saved != null &&
          raw != saved &&
          chain.own.isNotEmpty &&
          remote.ancestors.isNotEmpty &&
          !remote.ancestors.contains(_digest(saved))) {
        final base = chain.base;
        final ancestor =
            base != null &&
            (base == raw ||
                remote.ancestors.contains(_digest(base)) ||
                chain.own.any(remote.ancestors.contains));
        if (ancestor) {
          baseline = _Manifest.read(base);
        } else {
          baseline = null;
          lostBase = true;
        }
      }
      if (!connecting && remote == null) {
        throw StateError(
          'Файл PepeHub-library/library.json недоступен. '
          'Проверьте папку и дождитесь синхронизации. Локальные изменения сохранены.',
        );
      }
      if (baseline != null && baseline.id != remote!.id) {
        throw StateError(
          'В папке другая библиотека. Отключите папку и выберите её заново.',
        );
      }
      _status();
      // Copy a consistent working snapshot, then release SQLite while doing
      // potentially slow folder IO. Recheck the revision before publishing.
      var imported = false;
      String? publishedManifest;
      final snapshot = await library.local.db.transaction(() async {
        // A native note/session may have committed while the manifest was read.
        revision = await _revision();
        if (connecting ||
            _lastRevision == null ||
            revision.split(':').last != _lastRevision!.split(':').last) {
          await library.history!.capture(includeDeleted: true);
          await library.notes!.capture(includeDeleted: true);
        }
        final cards = await library.repository.entries();
        final history =
            await library.local.meta(library.history!.key) ?? '{"slots":{}}';
        final notes =
            await library.local.meta(library.notes!.key) ?? '{"slots":{}}';
        final settings = await library.local.metadataPrefixes(
          _settingsPrefixes,
        );
        settings.removeWhere((key, _) => !_portableSetting(key));
        return (
          cards: cards,
          history: history,
          notes: notes,
          settings: settings,
          revision: await _revision(),
        );
      });
      revision = snapshot.revision;
      final cards = snapshot.cards;
      final items = {
        for (final e in cards.entries)
          if (isSeriesCatalogItem(e.value.item)) e.key: e.value.item.toJson(),
      };
      final local = await _folderWork(_snapshot, (
        items,
        snapshot.history,
        snapshot.notes,
        snapshot.settings,
      ));
      final hashes = await _folderWork(_hashDocuments, local);
      final merged = <String, String>{};
      final conflicts = <String>[];
      final journalMerges =
          <String, ({String here, String there, String? before})>{};
      final journalDocuments = <String, String>{};
      for (final key in {
        ...hashes.keys,
        ...?remote?.documents.keys,
        ...?baseline?.documents.keys,
      }) {
        final here = hashes[key],
            there = remote?.documents[key],
            before = baseline?.documents[key];
        final journal = key.startsWith('history/') || key.startsWith('notes/');
        String? chosen;
        if (remote == null || here == there) {
          chosen = here;
        } else if (baseline == null && (connecting || lostBase)) {
          chosen = here ?? there;
          if (here != null && there != null && here != there) {
            if (journal) {
              journalMerges[key] = (here: here, there: there, before: null);
            } else {
              if (preference == null) conflicts.add(key);
              chosen = preference == LibraryFolderPreference.folder
                  ? there
                  : here;
            }
          }
        } else if (here == before) {
          chosen = there;
        } else if (there == before) {
          chosen = here;
        } else if (journal && here != null && there != null) {
          chosen = here;
          journalMerges[key] = (here: here, there: there, before: before);
        } else {
          if (preference == null) conflicts.add(key);
          chosen = preference == LibraryFolderPreference.folder ? there : here;
        }
        if (chosen != null) merged[key] = chosen;
      }
      // Both devices added sessions or notes to the same work: keep both.
      for (final e in journalMerges.entries) {
        final theirs = await _read(fs, _objectPath(e.value.there), 16777216);
        if (theirs == null) {
          throw LibraryFolderPending(
            'Данные ${e.key} ещё не синхронизированы. PepeHub повторит проверку.',
          );
        }
        String? base;
        if (e.value.before case final before?) {
          try {
            final bytes = await _read(fs, _objectPath(before), 16777216);
            if (bytes != null) base = utf8.decode(bytes);
          } on Object {
            // Old versions may be cleaned up: a union keeps every entry.
          }
        }
        final raw = mergeLibraryJournal(
          e.key.split('/').first,
          local[e.key]!,
          utf8.decode(theirs),
          base,
        );
        final digest = _digest(raw);
        merged[e.key] = digest;
        journalDocuments[e.key] = raw;
      }
      // A purge on one device can race with a new note/session on another.
      // Resolve that work as a unit so a chosen journal keeps its card.
      final orphaned = {
        for (final key in merged.keys)
          if ((key.startsWith('history/') || key.startsWith('notes/')) &&
              !merged.containsKey('cards/${key.split('/')[1]}'))
            key.split('/')[1],
      };
      for (final id in orphaned) {
        if (preference == null) {
          conflicts.add('cards/$id');
        } else {
          final preferred = preference == LibraryFolderPreference.local
              ? hashes
              : remote?.documents ?? <String, String>{};
          merged.removeWhere((key, _) => key.endsWith('/$id'));
          merged.addEntries(
            preferred.entries.where((e) => e.key.endsWith('/$id')),
          );
        }
      }
      if (conflicts.isNotEmpty) throw LibraryFolderConflict(conflicts);
      final data = <String, String>{};
      var total = 0;
      for (final e in merged.entries) {
        if (hashes[e.key] == e.value) {
          data[e.key] = local[e.key]!;
        } else if (journalDocuments[e.key] case final raw?
            when _digest(raw) == e.value) {
          data[e.key] = raw;
        } else {
          final bytes = await _read(fs, _objectPath(e.value), 16777216);
          if (bytes == null) {
            throw LibraryFolderPending(
              'Данные ${e.key} ещё не синхронизированы. PepeHub повторит проверку.',
            );
          }
          if (sha256.convert(bytes).toString() != e.value) {
            throw StateError('Данные ${e.key} повреждены в папке.');
          }
          data[e.key] = utf8.decode(bytes);
        }
        final size = utf8.encode(data[e.key]!).length;
        if (size > 16777216) {
          throw FormatException('Слишком большой документ: ${e.key}');
        }
        total += size;
        if (total > 268435456) {
          throw const FormatException('Библиотека больше 256 МиБ');
        }
      }
      final decoded = await _folderWork(_validate, data);
      final nonArchiveIds = {
        for (final e in decoded.entries)
          if (e.key.startsWith('cards/') &&
              !isSeriesCatalogItem(LibraryItem.fromJson(e.value)))
            e.key.substring('cards/'.length),
      };
      for (final id in nonArchiveIds) {
        for (final kind in ['cards', 'history', 'notes']) {
          final key = '$kind/$id';
          decoded.remove(key);
          merged.remove(key);
        }
      }
      final firstNamedSave = await fs.hash(_bookFilesPath) == null;
      if (raw != null &&
          firstNamedSave &&
          await fs.hash(_beforeNamedBooks) == null) {
        await _write(fs, _beforeNamedBooks, utf8.encode(raw), null);
      }
      final availableCovers = await _covers(fs, decoded, remote?.covers ?? {});
      for (final e in merged.entries) {
        if (_disposed) throw StateError('Хранилище библиотеки закрыто');
        if (remote?.documents[e.key] == e.value) continue;
        final path = _objectPath(e.value),
            existing = await fs.hash(_objectPath(e.value));
        if (existing != null && existing != e.value) {
          throw StateError('Повреждён объект библиотеки: $path');
        }
        if (existing == null) {
          await _write(fs, path, utf8.encode(data[e.key]!), null);
        }
      }
      final sameContent =
          remote != null &&
          sameMetadataValue(remote.documents, merged) &&
          setEquals(remote.covers, availableCovers);
      final next = _Manifest(
        remote?.id ?? uuid.v4(),
        merged,
        availableCovers,
        raw == null
            ? const []
            : sameContent
            ? remote.ancestors
            : [_digest(raw), ...remote!.ancestors].take(_maxAncestors).toList(),
      );
      final readme = await fs.hash('${_prefix}README.md');
      if (readme == null ||
          readme == _digest(_legacyFolderReadme) ||
          readme == _digest(_previousFolderReadme) ||
          readme == _digest(_releasedFolderReadme)) {
        await _write(
          fs,
          '${_prefix}README.md',
          utf8.encode(_folderReadme),
          readme,
        );
      }
      final encoded = _encode(next.toJson());
      if (utf8.encode(encoded).length > 16777216) {
        throw const FormatException('Каталог библиотеки превышает 16 МиБ');
      }
      await library.local.db.transaction(() async {
        if (_disposed) throw StateError('Хранилище библиотеки закрыто');
        if (await _revision() != snapshot.revision) {
          throw _LibraryChangedDuringSave();
        }
        if (encoded != raw) {
          await _write(
            fs,
            _manifestPath,
            utf8.encode(encoded),
            raw == null ? null : _digest(raw),
          );
        } else if (await fs.hash(_manifestPath) != _digest(raw!)) {
          throw StateError(
            'Каталог изменился во время чтения. Повторите обновление.',
          );
        }
        imported = !sameMetadataValue(hashes, merged);
        if (imported) await _apply(decoded, cards);
        await library.local.setMeta(_folderKey, selected);
        await library.local.setMeta(_layoutKey, direct ? 'root' : 'nested');
        await library.local.setMeta(_baselineKey, encoded);
        // A catalog we did not write is confirmed: it becomes the base of
        // our next writes. Our own writes stay pending until another catalog
        // lists them among its ancestors.
        // Without pending writes, the catalog we build on is the base too.
        final foreign = raw != null && raw != saved;
        final restart = connecting || foreign || chain.own.isEmpty;
        final own = restart ? <String>[] : [...chain.own];
        // A brand-new catalog has no parent: it is the base itself.
        if (encoded != raw && !(restart && raw == null)) {
          own.add(_digest(encoded));
        }
        await library.local.setMeta(
          _chainKey,
          _Chain(
            restart ? raw ?? encoded : chain.base,
            own.length > _maxAncestors
                ? own.sublist(own.length - _maxAncestors)
                : own,
          ).encode(),
        );
        revision = await _revision();
        // Assign only after the transaction commits below.
        publishedManifest = encoded;
      });
      _lastRevision = revision;
      _lastManifest = publishedManifest;
      // The next poll verifies the published manifest by content once.
      _lastManifestStamp = null;
      _direct = direct;
      savedAt = checkedAt = DateTime.now();
      error = null;
      pending = null;
      stats = _statsOf(decoded, availableCovers.length);
      try {
        await _publishNamedBooks(
          fs,
          decoded,
          encoded,
          force: force || connecting,
        );
      } catch (e) {
        _lastManifest = _lastManifestStamp = null;
        error =
            'Не удалось обновить именованные файлы книг: ${describeError(e)}';
      }
      final due =
          _lastCleanup == null ||
          DateTime.now().difference(_lastCleanup!) >= _cleanupEvery;
      if (due && fs.localLibrary != null) {
        _lastCleanup = DateTime.now();
        try {
          await _cleanup(fs, {
            next,
            ?previous,
            if (chain.base case final base?) _Manifest.read(base),
          });
        } catch (e) {
          debugPrint('Library folder cleanup failed: ${describeError(e)}');
        }
      }
      _status();
      return imported;
    } on LibraryFolderPending catch (e) {
      // Another device's files are still arriving: not an error yet.
      _lastManifest = _lastManifestStamp = null;
      error = null;
      pending = e.message;
      _status();
      rethrow;
    } catch (e) {
      if (e is _LibraryChangedDuringSave && attempt < 2 && !_disposed) {
        return await _synchronize(
          selected,
          force: true,
          connecting: connecting,
          preference: preference,
          attempt: attempt + 1,
        );
      }
      if (e is _LibraryChangedDuringSave) {
        error = 'Библиотека менялась во время сохранения. Повторите обновление папки.';
        throw StateError(error!);
      }
      error = describeError(e);
      _status();
      rethrow;
    } finally {
      working = false;
      _status();
    }
  }

  Future<void> _publishNamedBooks(
    _FolderFiles fs,
    Map<String, dynamic> data,
    String manifest, {
    required bool force,
  }) async {
    final bytes = await _read(fs, _bookFilesPath, 16777216);
    final raw = bytes == null ? null : utf8.decode(bytes);
    final previous = raw == null
        ? <String, String>{}
        : Map<String, String>.from(jsonDecode(raw) as Map);
    for (final entry in previous.entries) {
      if (!RegExp(r'^(Книги|Корзина)/(?:[^/]+/)?[^/]+\.json$')
              .hasMatch(entry.key) ||
          !_hash.hasMatch(entry.value)) {
        throw const FormatException('Повреждён список именованных файлов книг');
      }
      folderPath(entry.key);
    }
    final previousPaths = {
      for (final path in previous.keys) path.toLowerCase(): path,
    };
    final previousDirectories = {
      for (final path in previous.keys)
        p.posix.dirname(path).toLowerCase(): p.posix.dirname(path),
    };
    final books = await _folderWork(_namedBooks, data);
    final used = {
      for (final path in books.keys)
        p.posix.withoutExtension(path).toLowerCase(),
    };
    final next = <String, String>{};
    for (final entry in books.entries) {
      if (_disposed) return;
      final directory = p.posix.dirname(entry.key);
      var path =
          previousPaths[entry.key.toLowerCase()] ??
          p.posix.join(
            previousDirectories[directory.toLowerCase()] ?? directory,
            p.posix.basename(entry.key),
          );
      final content = utf8.encode(entry.value.raw);
      final digest = sha256.convert(content).toString();
      if (force || previous[path] != digest) {
        var existing = await fs.hash('$_prefix$path');
        if (existing != null &&
            existing != digest &&
            existing != previous[path]) {
          // A manually edited or unrelated file stays in place.
          final base = _fileName(
            p.posix.basenameWithoutExtension(path),
            'Без названия',
          );
          final directory = p.posix.dirname(path);
          final occupied = p.posix.join(directory, base);
          used.add(occupied.toLowerCase());
          path = '${_uniqueName(occupied, entry.value.id, used)}.json';
          existing = await fs.hash('$_prefix$path');
          if (existing != null &&
              existing != digest &&
              existing != previous[path]) {
            throw StateError('Именованный файл уже занят: $path');
          }
        }
        if (existing != digest) {
          await _write(fs, '$_prefix$path', content, existing);
        }
      }
      next[path] = digest;
    }
    final encoded = _encode(next);
    if (encoded == raw) return;
    if (await fs.hash(_manifestPath) != _digest(manifest)) {
      throw StateError('Каталог изменился во время записи именованных файлов');
    }
    final paths = next.keys.map((path) => path.toLowerCase()).toSet();
    for (final entry in previous.entries) {
      if (!paths.contains(entry.key.toLowerCase()) &&
          await fs.hash('$_prefix${entry.key}') == entry.value) {
        await fs.remove('$_prefix${entry.key}', entry.value);
      }
    }
    await _write(
      fs,
      _bookFilesPath,
      utf8.encode(encoded),
      raw == null ? null : _digest(raw),
    );
  }

  static Map<String, dynamic> _validate(Map<String, String> documents) {
    if (documents.keys.where((key) => key.startsWith('cards/')).length >
        50000) {
      throw const FormatException('В библиотеке больше 50 000 карточек');
    }
    final decoded = documents.map((key, raw) => MapEntry(key, jsonDecode(raw)));
    final journalIds = {'notes': <String>{}, 'history': <String>{}};
    for (final e in decoded.entries) {
      final parts = e.key.split('/');
      if (e.key == 'settings') {
        if (e.value is! Map) {
          throw const FormatException('Повреждены настройки библиотеки');
        }
        for (final setting in (e.value as Map).entries) {
          if (setting.key is! String ||
              setting.value is! String ||
              !_portableSetting(setting.key as String) ||
              (setting.value as String).length > 10000) {
            throw const FormatException('Неизвестная настройка библиотеки');
          }
          final key = setting.key as String, value = setting.value as String;
          if (key.startsWith('obsidian-policy:')) {
            final policy = jsonDecode(value);
            if (policy is! Map ||
                policy.values.any(
                  (v) => !['auto', 'local', 'obsidian'].contains(v),
                )) {
              throw const FormatException('Повреждены правила обновления');
            }
          } else {
            final number = int.tryParse(value);
            if (number == null ||
                number < 0 ||
                number >
                    (key.startsWith('library-series-length:') ? 500 : 10000) ||
                key == 'library-trash-retention-days' &&
                    ![0, 7, 30, 90].contains(number)) {
              throw const FormatException(
                'Повреждено числовое значение библиотеки',
              );
            }
          }
        }
      } else if (parts[0] == 'cards') {
        final item = LibraryItem.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        );
        if (item.id != parts[1] ||
            !_uuid.hasMatch(item.id) ||
            !['book', 'audiobook'].contains(item.mediaType) ||
            item.path.isNotEmpty) {
          throw const FormatException('Повреждена карточка библиотеки');
        }
      } else {
        final card = decoded['cards/${parts[1]}'];
        if (card is! Map ||
            e.value is! Map ||
            (e.value as Map).length > 100000) {
          throw const FormatException('Журнал не связан с карточкой');
        }
        for (final slot in (e.value as Map).entries) {
          if (!(parts[0] == 'notes'
                  ? validNoteValue(slot.value)
                  : validActivityValue(slot.value)) ||
              slot.key != slot.value['id'] ||
              slot.value['itemId'] != parts[1] ||
              slot.value['mediaType'] != card['mediaType'] ||
              !journalIds[parts[0]]!.add(slot.key as String)) {
            throw const FormatException('Повреждена запись журнала библиотеки');
          }
          if (journalIds[parts[0]]!.length > 100000) {
            throw const FormatException('В журнале больше 100 000 записей');
          }
        }
      }
    }
    return decoded;
  }

  Future<Set<String>> _covers(
    _FolderFiles fs,
    Map<String, dynamic> data,
    Set<String> remote,
  ) async {
    final available = <String>{};
    for (final e in data.entries.where((e) => e.key.startsWith('cards/'))) {
      final item = LibraryItem.fromJson(
        Map<String, dynamic>.from(e.value as Map),
      );
      final hash = library.coverHash(item);
      if (hash == null || available.contains(hash)) continue;
      final cached = library.coverPath(item);
      Uint8List? cachedBytes;
      if (cached != null) {
        final file = File(cached);
        if (await file.length() <= 2097152) {
          final bytes = await file.readAsBytes();
          if (CoverSync.validPng(bytes) &&
              sha256.convert(bytes).toString() == hash) {
            cachedBytes = bytes;
          }
        }
        if (cachedBytes == null && !remote.contains(hash)) {
          throw StateError('Повреждена обложка: ${item.title}');
        }
      }
      if (cachedBytes != null) {
        final existing = await fs.hash(_coverPath(hash));
        if (existing != null && existing != hash) {
          throw StateError('Повреждена обложка в папке');
        }
        if (existing == null) {
          await _write(fs, _coverPath(hash), cachedBytes, null);
        }
        available.add(hash);
      } else if (remote.contains(hash)) {
        final bytes = await _read(fs, _coverPath(hash), 2097152);
        if (bytes == null) {
          throw LibraryFolderPending(
            'Обложка ещё не синхронизирована: ${item.title}',
          );
        }
        if (!CoverSync.validPng(bytes) ||
            sha256.convert(bytes).toString() != hash) {
          throw StateError(
            'Обложка ещё не синхронизирована или повреждена: ${item.title}',
          );
        }
        if (library.covers == null) {
          throw StateError('Хранилище обложек недоступно');
        }
        final target = File(library.covers!.path(hash));
        await target.parent.create(recursive: true);
        final partial = File('${target.path}.${uuid.v4()}.folder');
        try {
          await partial.writeAsBytes(bytes, flush: true);
          await partial.rename(target.path);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
        available.add(hash);
      }
    }
    return available;
  }

  Future<void> _apply(
    Map<String, dynamic> data,
    Map<String, LibraryEntry> existing,
  ) async {
    await library.repository.mutate((cards) async {
      cards.removeWhere((_, entry) => isSeriesCatalogItem(entry.item));
      for (final e in data.entries.where((e) => e.key.startsWith('cards/'))) {
        final item = LibraryItem.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        );
        final prior = existing[item.id];
        cards[item.id] =
            prior != null &&
                sameMetadataValue(prior.item.toJson(), item.toJson())
            ? prior
            : LibraryEntry(item, sourceBookId: prior?.sourceBookId);
      }
    });
    for (final pair in [
      (library.history!, 'history'),
      (library.notes!, 'notes'),
    ]) {
      await pair.$1.mutate((state) async {
        final old = Map<String, dynamic>.from(state['slots'] as Map);
        final slots = <String, dynamic>{
          for (final e in old.entries)
            if (existing[e.value['value']['itemId']] case final card?)
              if (!isSeriesCatalogItem(card.item) &&
                  !data.containsKey('cards/${card.item.id}'))
                e.key: e.value,
        };
        for (final e in data.entries.where(
          (e) => e.key.startsWith('${pair.$2}/'),
        )) {
          for (final value in (e.value as Map).entries) {
            final prior = old[value.key] as Map?;
            slots[value.key as String] = prior == null
                ? {'value': value.value, 'portable': true}
                : {...prior, 'value': value.value};
          }
        }
        state['slots'] = slots;
      });
    }
    final settings = Map<String, String>.from(data['settings'] as Map? ?? {});
    final old = await library.local.metadataPrefixes(_settingsPrefixes);
    old.removeWhere((key, _) => !_portableSetting(key));
    for (final key in old.keys.where((key) => !settings.containsKey(key))) {
      await library.local.db.customStatement(
        'DELETE FROM metadata WHERE key=?',
        [key],
      );
    }
    for (final e in settings.entries) {
      await library.local.setMeta(e.key, e.value);
    }
    await library.local.setMeta('library-legacy-migration-v1', '1');
    await library.local.setMeta('library-manual-archive-v1', '1');
  }

  /// Only native journals (reading/listening sessions, notes) changed since
  /// [last]: every native change bumps both counters by the same amount.
  static bool _onlyJournal(String current, String? last) {
    if (last == null) return false;
    final now = current.split(':').map(int.parse).toList(),
        before = last.split(':').map(int.parse).toList();
    final native = now[1] - before[1];
    return native > 0 && now[0] - before[0] == native;
  }

  void _clearProblems() {
    if (error == null && pending == null) return;
    error = null;
    pending = null;
    _status();
  }

  static LibraryFolderStats _statsOf(Map<String, dynamic> data, int covers) {
    var cards = 0, deleted = 0, history = 0, notes = 0;
    for (final e in data.entries) {
      if (e.key.startsWith('cards/')) {
        cards++;
        final item = LibraryItem.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        );
        if (isLibraryDeleted(item)) deleted++;
      } else if (e.key.startsWith('history/') || e.key.startsWith('notes/')) {
        final live = (e.value as Map).values
            .where((v) => (v as Map)['deleted'] != true)
            .length;
        if (e.key.startsWith('history/')) {
          history += live;
        } else {
          notes += live;
        }
      }
    }
    return LibraryFolderStats(
      cards: cards,
      deleted: deleted,
      history: history,
      notes: notes,
      covers: covers,
    );
  }

  /// Objects and covers in the folder on this computer, with their hashes.
  static Future<List<({String path, String hash, File file, bool cover})>>
  _stored(Directory library) async {
    final result = <({String path, String hash, File file, bool cover})>[];
    final objects = Directory(p.join(library.path, 'objects'));
    if (await objects.exists()) {
      await for (final dir in objects.list(followLinks: false)) {
        final shard = p.basename(dir.path);
        if (dir is! Directory || !RegExp(r'^[a-f0-9]{2}$').hasMatch(shard)) {
          continue;
        }
        await for (final file in dir.list(followLinks: false)) {
          final name = p.basename(file.path);
          if (file is! File || !name.endsWith('.json')) continue;
          final hash = name.substring(0, name.length - 5);
          if (!_hash.hasMatch(hash) || !hash.startsWith(shard)) continue;
          result.add((
            path: '${_prefix}objects/$shard/$name',
            hash: hash,
            file: file,
            cover: false,
          ));
        }
      }
    }
    final covers = Directory(p.join(library.path, 'covers'));
    if (await covers.exists()) {
      await for (final file in covers.list(followLinks: false)) {
        final name = p.basename(file.path);
        if (file is! File || !name.endsWith('.png')) continue;
        final hash = name.substring(0, name.length - 4);
        if (!_hash.hasMatch(hash)) continue;
        result.add((
          path: '${_prefix}covers/$name',
          hash: hash,
          file: file,
          cover: true,
        ));
      }
    }
    return result;
  }

  /// Removes objects and covers that no kept catalog references, once they
  /// have been unreferenced for [libraryFolderCleanupAge] as seen by this
  /// device and the file itself is at least that old. New files written by
  /// another device whose catalog has not arrived yet are therefore never
  /// touched. Runs only on computers, where listing the folder is cheap; the
  /// sync tool carries the deletions to other devices.
  Future<int> _cleanup(_FolderFiles fs, Set<_Manifest> keep) async {
    final library = fs.localLibrary;
    if (library == null) return 0;
    final documents = {for (final m in keep) ...m.documents.values};
    final covers = {for (final m in keep) ...m.covers};
    final raw = await this.library.local.meta(_cleanupKey);
    final seen = raw == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final now = DateTime.now();
    final next = <String, String>{};
    var removed = 0;
    for (final file in await _stored(library)) {
      if (_disposed) return removed;
      if ((file.cover ? covers : documents).contains(file.hash)) continue;
      final key = '${file.cover ? 'c' : 'o'}:${file.hash}';
      final first = DateTime.tryParse('${seen[key]}') ?? now;
      final modified = (await file.file.stat()).modified;
      if (now.difference(first) >= libraryFolderCleanupAge &&
          now.difference(modified) >= libraryFolderCleanupAge) {
        try {
          await fs.remove(file.path, file.hash);
          removed++;
          continue;
        } on Object catch (e) {
          debugPrint('Library folder cleanup kept ${file.path}: $e');
        }
      }
      next[key] = first.toUtc().toIso8601String();
    }
    if (removed > 0) {
      final objects = Directory(p.join(library.path, 'objects'));
      await for (final dir in objects.list(followLinks: false)) {
        if (dir is Directory &&
            RegExp(r'^[a-f0-9]{2}$').hasMatch(p.basename(dir.path)) &&
            await dir.list().isEmpty) {
          try {
            await dir.delete();
          } on FileSystemException {
            // Something arrived meanwhile.
          }
        }
      }
    }
    await this.library.local.setMeta(_cleanupKey, jsonEncode(next));
    return removed;
  }

  _FolderFiles? _current() => folder == null
      ? null
      : _FolderFiles(_fileSystem(folder!), direct: _direct);

  /// Directory with `.stfolder` at or above the selected folder.
  static Future<Directory?> _syncthingRoot(Directory start) async {
    Directory? dir = start;
    for (var i = 0; i < 3 && dir != null; i++) {
      if (await Directory(p.join(dir.path, '.stfolder')).exists()) return dir;
      final parent = dir.parent;
      dir = parent.path == dir.path ? null : parent;
    }
    return null;
  }

  /// Folder details for the «Данные» screen; null on Android folders.
  Future<LibraryFolderReport?> inspect() async {
    await initialize();
    final fs = _current();
    final library = fs?.localLibrary, root = fs?.localRoot;
    if (fs == null || library == null || root == null) return null;
    final keep = <_Manifest>{};
    for (final raw in [
      await this.library.local.meta(_baselineKey),
      _Chain.read(await this.library.local.meta(_chainKey)).base,
    ]) {
      if (raw != null) keep.add(_Manifest.read(raw));
    }
    final documents = {for (final m in keep) ...m.documents.values};
    final covers = {for (final m in keep) ...m.covers};
    var objects = 0, unusedObjects = 0, unusedCovers = 0, unusedBytes = 0;
    for (final file in await _stored(library)) {
      if (!file.cover) objects++;
      if ((file.cover ? covers : documents).contains(file.hash)) continue;
      file.cover ? unusedCovers++ : unusedObjects++;
      unusedBytes += await file.file.length();
    }
    final conflicts = <String>[];
    var visited = 0;
    Future<void> walk(Directory dir, String prefix) async {
      await for (final entry in dir.list(followLinks: false)) {
        if (++visited > 20000) return;
        final name = p.basename(entry.path);
        if (name.toLowerCase() == '.pepehub') continue;
        if (entry is Directory) {
          await walk(entry, '$prefix$name/');
        } else if (entry is File && name.contains('.sync-conflict-')) {
          conflicts.add('$prefix$name');
        }
      }
    }

    if (await library.exists()) await walk(library, '');
    conflicts.sort();
    final syncthing = await _syncthingRoot(root);
    var ignores = false;
    if (syncthing != null) {
      final file = File(p.join(syncthing.path, '.stignore'));
      ignores =
          await file.exists() && _ignoresPepeHub(await file.readAsString());
    }
    return LibraryFolderReport(
      objects: objects,
      unusedObjects: unusedObjects,
      unusedCovers: unusedCovers,
      unusedBytes: unusedBytes,
      conflictCopies: conflicts,
      syncthingRoot: syncthing?.path,
      ignoresTemporary: ignores,
    );
  }

  /// Deletes Syncthing conflict copies inside PepeHub-library. Catalog
  /// copies are not needed: the device whose catalog was replaced merges its
  /// changes again from its own database. Returns the number removed.
  Future<int> removeConflictCopies(List<String> paths) async {
    await initialize();
    return _serial(() async {
      final fs = _current();
      if (fs == null) return 0;
      var removed = 0;
      for (final path in paths) {
        if (!p.posix.basename(path).contains('.sync-conflict-')) continue;
        final full = '$_prefix${folderPath(path)}';
        final hash = await fs.hash(full);
        if (hash == null) continue;
        await fs.remove(full, hash);
        removed++;
      }
      return removed;
    });
  }

  /// Adds [syncthingIgnorePattern] (temporary files of writes) to Syncthing's
  /// ignore list.
  Future<void> ignoreTemporaryFiles(String syncthingRoot) async {
    final file = File(p.join(syncthingRoot, '.stignore'));
    final old = await file.exists() ? await file.readAsString() : '';
    if (_ignoresPepeHub(old)) return;
    final separator = old.isEmpty || old.endsWith('\n') ? '' : '\n';
    await file.writeAsString(
      '$old$separator// PepeHub: временные файлы записи библиотеки\n'
      '$syncthingIgnorePattern\n',
      flush: true,
    );
  }

  void _status() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
