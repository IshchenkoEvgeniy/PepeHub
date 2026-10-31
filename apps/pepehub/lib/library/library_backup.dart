import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'activity_store.dart';
import 'cover_sync.dart';
import 'library_service.dart';
import 'models.dart';
import 'note_store.dart';
import 'personal_library.dart';

class LibraryBackupPreview {
  final Map<String, LibraryEntry> cards;
  final Map<String, dynamic> history, notes;
  final Map<String, Uint8List> covers;
  final String createdAt;
  final Map<String, String> settings;
  const LibraryBackupPreview(
    this.cards,
    this.history,
    this.notes,
    this.covers,
    this.createdAt,
    this.settings,
  );
}

/// A portable library archive, without tokens, cloud settings or book file paths.
class LibraryBackup {
  final LibraryService library;
  LibraryBackup(this.library);
  Future<Directory> directory() async {
    final root =
        library.assets?.directory ?? await getApplicationSupportDirectory();
    return Directory(p.join(root.path, 'library-backups'))
        .create(recursive: true);
  }

  Future<Uint8List> create() async {
    await library.history!.capture();
    await library.notes!.capture();
    final cards = await library.repository.entries();
    final archive = Archive();
    final savedCovers = <String>{}, missingCovers = <String>[];
    var size = 0;
    for (final card in cards.values) {
      final hash = CoverSync.referenceHash(card.item.value('cover'));
      if (hash == null || !savedCovers.add(hash)) continue;
      final path = library.coverPath(card.item);
      if (path == null) {
        missingCovers.add(hash);
        continue;
      }
      final file = File(path);
      if (await file.length() > 2097152) {
        throw StateError('Слишком большая обложка');
      }
      final bytes = await file.readAsBytes();
      if (!CoverSync.validPng(bytes) ||
          sha256.convert(bytes).toString() != hash) {
        throw StateError('Повреждена обложка: ${card.item.title}');
      }
      size += bytes.length;
      if (size > 134217728) throw StateError('Обложки занимают больше 128 МиБ');
      archive.addFile(ArchiveFile('covers/$hash.png', bytes.length, bytes));
    }
    Map<String, dynamic> portable(Map<String, dynamic> state) => {
      'version': 1,
      'cursor': 0,
      'slots': {
        for (final e in (state['slots'] as Map).entries)
          if (cards.containsKey((e.value as Map)['value']['itemId']))
            e.key: {
              'value': (e.value as Map)['value'],
              if ((e.value as Map)['source'] != null)
                'source': (e.value as Map)['source'],
              if ((e.value as Map)['native'] != null)
                'native': (e.value as Map)['native'],
            },
      },
    };
    final json = utf8.encode(
      jsonEncode({
        'format': 'pepehub-library',
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'cards': {for (final e in cards.entries) e.key: e.value.toJson()},
        'history': portable(await library.history!.state()),
        'notes': portable(await library.notes!.state()),
        'missingCovers': missingCovers,
        'settings': await library.local.metadataPrefixes([
          'library-series-length:',
          'library-year-goal:personal:',
          'obsidian-policy:personal:',
        ]),
      }),
    );
    if (json.length > 16777216) {
      throw StateError('Данные библиотеки превышают 16 МиБ');
    }
    archive.addFile(ArchiveFile('library.json', json.length, json));
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive));
    if (encoded.length > 134217728 || archive.files.length > 10001) {
      throw StateError('Библиотека превышает поддерживаемый размер копии');
    }
    return encoded;
  }

  Future<File> saveLocal() async {
    final folder = await directory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final file = File(p.join(folder.path, 'PepeHub-library-$stamp.zip'));
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(await create(), flush: true);
    return partial.rename(file.path);
  }

  LibraryBackupPreview inspect(Uint8List bytes) {
    if (bytes.length > 134217728) {
      throw const FormatException('Архив больше 128 МиБ');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > 10001) {
      throw const FormatException('Слишком много файлов');
    }
    final covers = <String, Uint8List>{};
    Map<String, dynamic>? manifest;
    var size = 0;
    final names = <String>{};
    for (final file in archive.files) {
      if (!file.isFile ||
          !names.add(file.name) ||
          file.size > 16777216 ||
          (file.name != 'library.json' &&
              !RegExp(r'^covers/[a-f0-9]{64}\.png$').hasMatch(file.name))) {
        throw const FormatException(
          'Неизвестный или недопустимый файл в архиве',
        );
      }
      size += file.size;
      if (size > 150994944) {
        throw const FormatException('Распакованные данные слишком велики');
      }
      final content = Uint8List.fromList(file.content);
      if (content.length != file.size) {
        throw const FormatException('Повреждён файл архива');
      }
      if (file.name == 'library.json') {
        manifest = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(content)) as Map,
        );
      } else {
        final hash = file.name.substring(7, 71);
        if (!CoverSync.validPng(content) ||
            sha256.convert(content).toString() != hash) {
          throw const FormatException('Контрольная сумма обложки не совпала');
        }
        covers[hash] = content;
      }
    }
    final data = manifest;
    if (data == null ||
        data['format'] != 'pepehub-library' ||
        data['version'] != 1 ||
        data['cards'] is! Map ||
        (data['cards'] as Map).length > 50000 ||
        data['createdAt'] is! String ||
        DateTime.tryParse(data['createdAt']) == null) {
      throw const FormatException(
        'Неподдерживаемая резервная копия библиотеки',
      );
    }
    final cards = <String, LibraryEntry>{};
    final uuid = RegExp(
      r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
      caseSensitive: false,
    );
    for (final e in (data['cards'] as Map).entries) {
      final entry = LibraryEntry.fromJson(
        Map<String, dynamic>.from(e.value as Map),
      );
      if (e.key != entry.item.id ||
          !uuid.hasMatch(entry.item.id) ||
          !['book', 'audiobook'].contains(entry.item.mediaType)) {
        throw const FormatException('Повреждена карточка книги');
      }
      cards[e.key as String] = LibraryEntry(
        personalLibraryItem(
          entry.item.id,
          entry.item.mediaType,
          entry.item.values,
          modifiedAt: entry.item.modifiedAt,
        ),
        sourceBookId: entry.sourceBookId,
      );
    }
    Map<String, dynamic> state(String key, bool Function(dynamic) valid) {
      final value = data[key];
      if (value is! Map ||
          value['slots'] is! Map ||
          (value['slots'] as Map).length > 100000) {
        throw const FormatException('Повреждён журнал библиотеки');
      }
      for (final e in (value['slots'] as Map).entries) {
        final slot = e.value;
        if (slot is! Map ||
            !valid(slot['value']) ||
            slot['value']['id'] != e.key ||
            !cards.containsKey(slot['value']['itemId'])) {
          throw const FormatException('Повреждена запись журнала');
        }
        final source = slot['source'];
        if (source != null &&
            (source is! Map ||
                source.keys.any(
                  (k) => !['kind', 'id', 'bookId', 'span'].contains(k),
                ) ||
                !['reader', 'audio', 'manual'].contains(source['kind']) ||
                source['id'] is! String ||
                !uuid.hasMatch(source['id']) ||
                source['bookId'] is! String ||
                !uuid.hasMatch(source['bookId']) ||
                source['span'] != null &&
                    (source['span'] is! int ||
                        source['span'] < 0 ||
                        source['span'] > 1000000) ||
                slot['native'] != null && !valid(slot['native']))) {
          throw const FormatException('Недопустимая привязка записи журнала');
        }
      }
      return {'version': 1, 'cursor': 0, 'slots': value['slots']};
    }

    final settings = <String, String>{};
    for (final e in (data['settings'] as Map? ?? {}).entries) {
      if (e.key is! String ||
          e.value is! String ||
          ![
            'library-series-length:',
            'library-year-goal:personal:',
            'obsidian-policy:personal:',
          ].any((prefix) => (e.key as String).startsWith(prefix)) ||
          (e.value as String).length > 10000) {
        throw const FormatException('Недопустимые настройки в копии');
      }
      settings[e.key] = e.value;
      if ((e.key as String).startsWith('obsidian-policy:')) {
        final policy = jsonDecode(e.value as String);
        if (policy is! Map ||
            policy.values.any(
              (v) => !['auto', 'local', 'obsidian'].contains(v),
            )) {
          throw const FormatException(
            'Недопустимые правила обновления в копии',
          );
        }
      } else {
        final value = int.tryParse(e.value as String);
        if (value == null ||
            value < 0 ||
            value >
                ((e.key as String).startsWith('library-series-length:')
                    ? 500
                    : 10000)) {
          throw const FormatException('Недопустимое числовое значение в копии');
        }
      }
    }
    return LibraryBackupPreview(
      cards,
      state('history', validActivityValue),
      state('notes', validNoteValue),
      covers,
      data['createdAt'],
      settings,
    );
  }

  Future<void> restore(
    LibraryBackupPreview preview, {
    bool replace = false,
  }) async {
    // Recovery always keeps a local copy of the state it is about to change.
    await saveLocal();
    final coverStore = library.covers;
    if (preview.covers.isNotEmpty && coverStore == null) {
      throw StateError('Хранилище обложек недоступно');
    }
    for (final e in preview.covers.entries) {
      final file = File(coverStore!.path(e.key));
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.restore');
      await partial.writeAsBytes(e.value, flush: true);
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
    }
    await library.local.db.transaction(() async {
      await library.local.setMeta('library-legacy-migration-v1', '1');
      if (replace) {
        final retained = preview.cards.values
            .map((e) => e.sourceBookId)
            .toSet();
        await library.local.setMeta(
          'library-auto-excluded',
          jsonEncode([
            for (final book in await library.local.records('book'))
              if (!retained.contains(book.id)) book.id,
          ]),
        );
        final settings = await library.local.metadataPrefixes([
          'library-series-length:',
          'library-year-goal:personal:',
          'obsidian-policy:personal:',
        ]);
        for (final key in settings.keys) {
          await library.local.db.customStatement(
            'DELETE FROM metadata WHERE key=?',
            [key],
          );
        }
      }
      for (final e in preview.settings.entries) {
        await library.local.setMeta(e.key, e.value);
      }
      await library.repository.mutate((cards) async {
        if (replace) cards.clear();
        for (final e in preview.cards.entries) {
          var source = e.value.sourceBookId;
          if (source != null && await library.local.record(source) == null) {
            source = null;
          }
          final values = Map<String, dynamic>.from(e.value.item.values)
            ..remove('pepehub_source_revision_v1');
          cards[e.key] = LibraryEntry(
            e.value.item.withValues(values),
            sourceBookId: source,
          );
        }
      });
      for (final pair in [
        (library.history!, preview.history),
        (library.notes!, preview.notes),
      ]) {
        await pair.$1.mutate((state) async {
          final slots = state['slots'] as Map;
          if (replace) slots.clear();
          for (final e in (pair.$2['slots'] as Map).entries) {
            final incoming = e.value as Map, value = incoming['value'] as Map;
            final source = incoming['source'] as Map?;
            var nativeExists = false;
            if (source != null &&
                preview.cards[value['itemId']]?.sourceBookId ==
                    source['bookId']) {
              if (source['kind'] == 'reader') {
                nativeExists =
                    await library.local.meta(
                      '${pair.$1 is NoteStore ? 'reading-note' : 'reading-session'}:${source['id']}',
                    ) !=
                    null;
              } else {
                final record = await library.local.record(
                  source['id'] as String,
                );
                nativeExists =
                    record != null &&
                    !record.deleted &&
                    record.payload?['bookId'] == source['bookId'];
              }
            }
            slots[e.key] = {
              'value': value,
              'portable': !nativeExists,
              if (nativeExists) 'source': source,
              if (nativeExists) 'native': incoming['native'] ?? value,
            };
          }
        });
      }
    });
    await library.reload();
  }

  String exportText(String format) {
    final cards = library.visibleEntries;
    String text(dynamic value) =>
        value is List ? value.join(', ') : '${value ?? ''}';
    if (format == 'json') {
      return const JsonEncoder.withIndent('  ').convert({
        'format': 'pepehub-library-export',
        'version': 1,
        'books': [
          for (final e in cards)
            {'id': e.item.id, 'type': e.item.mediaType, ...e.item.values},
        ],
      });
    }
    const fields = [
      'title',
      'author',
      'series',
      'seriesIndex',
      'status',
      'rating',
      'startDate',
      'endDate',
      'rereadCount',
      'total',
      'progress',
      'unit',
      'notes',
    ];
    if (format == 'csv') {
      String cell(dynamic v) {
        var value = text(v);
        if (RegExp(r'^\s*[=+@-]').hasMatch(value)) value = "'$value";
        return '"${value.replaceAll('"', '""')}"';
      }

      return '\uFEFF${fields.join(',')}\r\n${cards.map((e) => fields.map((f) => cell(e.item.values[f])).join(',')).join('\r\n')}';
    }
    String literal(dynamic v) => text(v)
        .replaceAllMapped(RegExp(r'([\\`*_{}\[\]<>#!|])'), (m) => '\\${m[0]}');
    return '# Моя библиотека\n\n${cards.map((e) => '## ${literal(e.item.title)}\n\n${fields.skip(1).where((f) => text(e.item.values[f]).isNotEmpty).map((f) => '- $f: ${literal(e.item.values[f])}').join('\n')}\n').join('\n')}';
  }
}
