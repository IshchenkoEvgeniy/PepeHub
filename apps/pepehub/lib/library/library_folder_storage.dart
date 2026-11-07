import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart' show uuid;
import '../sync/peer/peer_files.dart';
import '../sync/peer/peer_models.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'library_features.dart';
import 'library_service.dart';
import 'models.dart';
import 'note_store.dart';
import 'personal_library.dart';

const _folderKey = 'library-storage-folder-v1';
const _baselineKey = 'library-storage-baseline-v1';
const _layoutKey = 'library-storage-layout-v1';
const _prefix = 'PepeHub-library/';
const _manifestPath = '${_prefix}library.json';
const _bookFilesPath = '${_prefix}objects/book-files.json';
const _beforeNamedBooks = '${_prefix}objects/library-before-named-books.json';
const _folderReadme = '''# PepeHub Library

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
    return peerPath(name);
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
      ObsidianLibraryItem.fromJson(data[key]),
  ];
  final seriesNames = <String, String>{};
  final usedSeries = <String>{};
  final usedPaths = <String>{};
  final books = <String, ({String id, String raw})>{};
  for (final item in items) {
    final series = '${item.value('series') ?? ''}'.trim();
    var directory = isLibraryDeleted(item) ? 'Корзина' : 'Книги';
    if (series.isNotEmpty) {
      final key = librarySeriesKey(item);
      final name = seriesNames.putIfAbsent(
        key,
        () => _uniqueName(
          _fileName(series, 'Серия'),
          _digest(key).substring(0, 12),
          usedSeries,
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

enum LibraryFolderPreference { local, folder }

class LibraryFolderConflict implements Exception {
  final List<String> documents;
  const LibraryFolderConflict(this.documents);
  @override
  String toString() =>
      'Библиотека изменена и здесь, и в папке '
      '(${documents.length} совпадающих записей). Выберите версию в разделе «Данные».';
}

class _Manifest {
  final String id;
  final Map<String, String> documents;
  final Set<String> covers;
  const _Manifest(this.id, this.documents, this.covers);
  Map<String, dynamic> toJson() => {
    'format': 'pepehub-library-folder',
    'version': 2,
    'id': id,
    'documents': documents,
    'covers': covers.toList()..sort(),
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
    return _Manifest(data['id'], documents, covers);
  }
}

class _FolderFiles {
  final PeerFileSystem files;
  final bool direct;
  const _FolderFiles(this.files, {required this.direct});
  String _path(String path) => direct ? path.substring(_prefix.length) : path;
  Future<String?> hash(String path) => files.hash(_path(path));
  Future<List<int>> read(String path, int offset, int count) =>
      files.read(_path(path), offset, count);
  Future<PeerStagingFile> stage(PeerFileEntry entry) =>
      files.stage(entry.withClock(entry.clock, path: _path(entry.path)));
  Future<void> remove(String path, String expected) =>
      files.remove(_path(path), expected);
}

class _LibraryChangedDuringSave implements Exception {}

/// A portable folder is the durable exchange format; SQLite is a transactional
/// working cache. Immutable objects are published before the small manifest.
/// A persisted three-way baseline also protects edits pending after a crash.
class LibraryFolderStorage extends ChangeNotifier {
  final LibraryService library;
  final PeerFileSystem Function(String) _fileSystem;
  LibraryFolderStorage(
    this.library, {
    PeerFileSystem Function(String)? fileSystem,
  }) : _fileSystem = fileSystem ?? peerFileSystem;
  String? folder;
  String? error;
  String? warning;
  DateTime? savedAt;
  bool working = false, _disposed = false;
  Future<void>? _initialized;
  Future<void> _tail = Future.value();
  Timer? _timer;
  String? _lastRevision, _lastManifest;
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
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
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
          'DELETE FROM metadata WHERE key IN (?,?,?)',
          [_folderKey, _baselineKey, _layoutKey],
        );
      });
      folder = null;
      _timer?.cancel();
      _timer = null;
      error = null;
      warning = null;
      _direct = false;
      _lastRevision = _lastManifest = null;
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
      final chunk = await fs.read(path, offset, peerChunkSize);
      bytes.add(chunk);
      offset += chunk.length;
      if (offset > limit) {
        throw FormatException('Слишком большой файл библиотеки: $path');
      }
      if (chunk.length < peerChunkSize) break;
    }
    final result = bytes.takeBytes();
    if (sha256.convert(result).toString() != expected) {
      throw StateError('Файл ещё синхронизируется: $path');
    }
    return result;
  }

  Future<void> _write(
    _FolderFiles fs,
    String path,
    List<int> bytes,
    String? expected,
  ) async {
    final stage = await fs.stage(
      PeerFileEntry(
        path: path,
        hash: sha256.convert(bytes).toString(),
        bytes: bytes.length,
        clock: const {'00000000-0000-4000-8000-000000000001': 1},
      ),
    );
    try {
      await stage.prepare();
      await stage.reset();
      for (var at = 0; at < bytes.length; at += peerChunkSize) {
        await stage.append(
          at,
          bytes.sublist(at, (at + peerChunkSize).clamp(0, bytes.length)),
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
      final manifestBytes = await _read(fs, _manifestPath, 16777216);
      final raw = manifestBytes == null ? null : utf8.decode(manifestBytes);
      var revision = await _revision();
      if (!connecting &&
          !force &&
          revision == _lastRevision &&
          raw == _lastManifest) {
        if (error != null) {
          error = null;
          _status();
        }
        return false;
      }
      final remote = raw == null ? null : _Manifest.read(raw);
      final saved = await library.local.meta(_baselineKey);
      final previous = saved == null ? null : _Manifest.read(saved);
      final baseline =
          !connecting || remote != null && previous?.id == remote.id
          ? previous
          : null;
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
      for (final key in {
        ...hashes.keys,
        ...?remote?.documents.keys,
        ...?baseline?.documents.keys,
      }) {
        final here = hashes[key],
            there = remote?.documents[key],
            before = baseline?.documents[key];
        String? chosen;
        if (remote == null || here == there) {
          chosen = here;
        } else if (connecting && baseline == null) {
          chosen = here ?? there;
          if (here != null && there != null && here != there) {
            if (preference == null) conflicts.add(key);
            chosen = preference == LibraryFolderPreference.folder
                ? there
                : here;
          }
        } else if (here == before) {
          chosen = there;
        } else if (there == before) {
          chosen = here;
        } else {
          if (preference == null) conflicts.add(key);
          chosen = preference == LibraryFolderPreference.folder ? there : here;
        }
        if (chosen != null) merged[key] = chosen;
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
        } else {
          final bytes = await _read(fs, _objectPath(e.value), 16777216);
          if (bytes == null || sha256.convert(bytes).toString() != e.value) {
            throw StateError(
              'Данные ${e.key} ещё не синхронизированы или повреждены. Повторите обновление.',
            );
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
              !isSeriesCatalogItem(ObsidianLibraryItem.fromJson(e.value)))
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
      final next = _Manifest(remote?.id ?? uuid.v4(), merged, availableCovers);
      final readme = await fs.hash('${_prefix}README.md');
      if (readme == null || readme == _digest(_legacyFolderReadme)) {
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
        revision = await _revision();
        // Assign only after the transaction commits below.
        publishedManifest = encoded;
      });
      _lastRevision = revision;
      _lastManifest = publishedManifest;
      _direct = direct;
      savedAt = DateTime.now();
      error = null;
      try {
        await _publishNamedBooks(
          fs,
          decoded,
          encoded,
          force: force || connecting,
        );
      } catch (e) {
        _lastManifest = null;
        error = 'Не удалось обновить именованные файлы книг: $e';
      }
      _status();
      return imported;
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
      error = '$e';
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
      peerPath(entry.key);
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
        final item = ObsidianLibraryItem.fromJson(
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
      final item = ObsidianLibraryItem.fromJson(
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
        if (bytes == null ||
            !CoverSync.validPng(bytes) ||
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
        final item = ObsidianLibraryItem.fromJson(
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

  void _status() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
