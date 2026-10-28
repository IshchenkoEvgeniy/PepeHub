import 'dart:io';

import 'package:drift/drift.dart';

import '../data/repository.dart';
import '../reader/reading_library.dart';
import '../audio/audio_journal.dart';
import '../media/asset_store.dart';
import 'activity_store.dart';
import 'library_repository.dart';
import 'models.dart';

bool validNoteValue(dynamic v) {
  if (v is! Map) return false;
  const keys = [
    'id',
    'itemId',
    'mediaType',
    'kind',
    'title',
    'quote',
    'text',
    'tags',
    'characters',
    'color',
    'anchor',
    'origin',
    'updatedAt',
    'deleted',
  ];
  final id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  bool text(dynamic x, int limit) => x is String && x.length <= limit;
  bool labels(dynamic x) =>
      x is List && x.length <= 40 && x.every((s) => text(s, 80));
  if (v.length != keys.length ||
      v.keys.any((k) => !keys.contains(k)) ||
      !text(v['id'], 36) ||
      !id.hasMatch(v['id'] as String) ||
      !text(v['itemId'], 36) ||
      !id.hasMatch(v['itemId'] as String)) {
    return false;
  }
  if (!['book', 'audiobook'].contains(v['mediaType']) ||
      !['reader', 'audio', 'markdown'].contains(v['kind']) ||
      v['kind'] == 'reader' && v['mediaType'] != 'book' ||
      v['kind'] == 'audio' && v['mediaType'] != 'audiobook') {
    return false;
  }
  if (!text(v['title'], 200) ||
      !text(v['quote'], 100000) ||
      !text(v['text'], v['kind'] == 'audio' ? 10000 : 100000) ||
      !labels(v['tags']) ||
      !labels(v['characters']) ||
      !text(v['color'], 40) ||
      v['deleted'] is! bool ||
      !['app-reader', 'app-audio', 'obsidian'].contains(v['origin'])) {
    return false;
  }
  if (v['kind'] == 'audio' &&
      ((v['text'] as String).trim().isEmpty || v['quote'] != '')) {
    return false;
  }
  if (v['updatedAt'] is! String ||
      !(v['updatedAt'] as String).endsWith('Z') ||
      DateTime.tryParse(v['updatedAt'] as String) == null) {
    return false;
  }
  final anchor = v['anchor'];
  if (anchor is! Map) return false;
  for (final e in anchor.entries) {
    if (['hash', 'trackHash'].contains(e.key)) {
      if (e.value is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(e.value as String)) {
        return false;
      }
    } else if (e.key == 'noteKind') {
      if (!['thought', 'quote', 'character'].contains(e.value)) return false;
    } else if (![
          'chapter',
          'start',
          'end',
          'positionMs',
          'trackIndex',
        ].contains(e.key) ||
        e.value is! int ||
        (e.value as int) < (e.key == 'chapter' ? -1 : 0) ||
        (e.value as int) > 1000000000000) {
      return false;
    }
  }
  return true;
}

/// Uses the journal's durable operation/receipt queue with a separate namespace and feed.
class NoteStore extends ActivityStore {
  NoteStore(super.local, super.namespace, {super.catalog});
  @override
  bool validEntry(dynamic value) => validNoteValue(value);
  @override
  String get key => 'obsidian-notes:$namespace';
  @override
  Future<List<Map<String, dynamic>>> entries({String? itemId}) async =>
      (await super.entries(itemId: itemId))..sort(
        (a, b) => '${b['value']['updatedAt']}'.compareTo(
          '${a['value']['updatedAt']}',
        ),
      );

  Map<String, dynamic> _reader(
    ReadingNote n,
    ObsidianLibraryItem item,
    Map? prior,
  ) => {
    'id': prior?['id'] ?? uuid.v5(item.id, 'reader-note:${n.id}'),
    'itemId': item.id,
    'mediaType': item.mediaType,
    'kind': prior?['kind'] ?? 'reader',
    'title': (prior?['kind'] == 'markdown')
        ? (prior?['title'] ?? 'Заметки Obsidian')
        : n.chapterTitle.substring(0, n.chapterTitle.length.clamp(0, 200)),
    'quote': n.quote,
    'text': n.comment,
    'tags': n.tags,
    'characters': n.characters,
    'color': n.color,
    'anchor':
        prior?['anchor'] ??
        {'hash': n.hash, 'chapter': n.chapter, 'start': n.start, 'end': n.end},
    'origin': prior?['origin'] ?? 'app-reader',
    'updatedAt': n.updated,
    'deleted': false,
  };
  Future<Map<String, dynamic>> _audio(
    LibraryRecord row,
    ObsidianLibraryItem item,
    Map? prior, [
    List<LocalAsset>? trackList,
  ]) async {
    final data = row.payload!;
    final tracks =
        trackList ??
        await AssetStore(
          local,
          Directory('.'),
        ).audioTracks(data['bookId'] as String);
    final index = tracks.indexWhere((t) => t.id == data['trackId']);
    return {
      'id': prior?['id'] ?? uuid.v5(item.id, 'audio-note:${row.id}'),
      'itemId': item.id,
      'mediaType': item.mediaType,
      'kind': 'audio',
      'title': data['title'] ?? '',
      'quote': '',
      'text': data['text'] ?? '',
      'tags': prior?['tags'] ?? [],
      'characters': prior?['characters'] ?? [],
      'color': prior?['color'] ?? 'yellow',
      'anchor': {
        'positionMs': data['positionMs'] ?? 0,
        'noteKind': data['kind'] ?? 'thought',
        if (index >= 0 &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(tracks[index].hash))
          'trackHash': tracks[index].hash,
        if (index >= 0) 'trackIndex': index,
      },
      'origin': prior?['origin'] ?? 'app-audio',
      'updatedAt': data['updatedAt'] ?? data['at'],
      'deleted': row.deleted,
    };
  }

  Map<String, dynamic>? _repairLinkedAudioAnchor(dynamic value) {
    if (value is! Map || value['kind'] != 'audio') return null;
    final anchor = value['anchor'];
    if (anchor is! Map ||
        anchor['trackHash'] is! String ||
        !(anchor['trackHash'] as String).startsWith('external:') ||
        anchor['trackIndex'] is! int ||
        (anchor['trackIndex'] as int) < 0) {
      return null;
    }
    final next = Map<String, dynamic>.from(value);
    next['anchor'] = Map<String, dynamic>.from(anchor)..remove('trackHash');
    return validNoteValue(next) ? next : null;
  }

  @override
  void preparePending(Map<String, dynamic> state) {
    for (final slot in (state['slots'] as Map).values) {
      if (slot['conflict'] != null) continue;
      final operation = slot['operation'];
      if (operation is! Map ||
          _repairLinkedAudioAnchor(operation['entry']) == null) {
        continue;
      }
      final next = _repairLinkedAudioAnchor(slot['value']) ?? slot['value'];
      if (!validNoteValue(next)) continue;
      slot['value'] = next;
      slot['native'] =
          _repairLinkedAudioAnchor(slot['native']) ?? slot['native'];
      // The server rejects external IDs in trackHash before accepting any
      // operation. Retire only those invalid requests; valid retries keep
      // their original UUID and immutable payload.
      slot.remove('operation');
    }
  }

  @override
  Future<void> capture() => local.db.transaction(() async {
    final links =
        (await (catalog ?? LibraryRepository(local, namespace)).entries())
            .values
            .where((e) => e.state == 'synced' && e.sourceBookId != null);
    final byBook = {for (final e in links) e.sourceBookId!: e.item};
    await mutate((state) async {
      final slots = state['slots'] as Map<String, dynamic>;
      // Materialize notes first when a file was linked after its remote notes arrived.
      for (final slot in slots.values.toList()) {
        if (slot['source'] == null && slot['conflict'] == null) {
          await _apply(slot, Map<String, dynamic>.from(slot['value']));
        }
      }
      final values = <String, Map<String, dynamic>>{},
          sources = <String, Map<String, dynamic>>{};
      final priorBySource = <(String, String, String, String), Map>{};
      for (final slot in slots.values) {
        final source = slot['source'] as Map?;
        if (source == null) continue;
        priorBySource.putIfAbsent((
          source['kind'] as String,
          source['id'] as String,
          source['bookId'] as String,
          slot['value']['itemId'] as String,
        ), () => slot);
      }
      Map? prior(String kind, String id, String book) =>
          priorBySource[(kind, id, book, byBook[book]!.id)]?['native'];
      void add(
        Map<String, dynamic> value,
        String kind,
        String id,
        String book,
      ) {
        values[value['id'] as String] = value;
        sources[value['id'] as String] = {
          'kind': kind,
          'id': id,
          'bookId': book,
        };
      }

      for (final n in await ReadingLibrary(
        local,
      ).notes(bookIds: byBook.keys.toSet())) {
        add(
          _reader(n, byBook[n.bookId]!, prior('reader', n.id, n.bookId)),
          'reader',
          n.id,
          n.bookId,
        );
      }
      final rows = await local.db
          .customSelect("SELECT * FROM records WHERE type='audio_note'")
          .get();
      final tracksByBook = <String, List<LocalAsset>>{};
      for (final row in rows) {
        final note = LibraryRecord.fromRow(row),
            book = note.payload?['bookId'] as String?;
        if (book == null || byBook[book] == null) continue;
        add(
          await _audio(
            note,
            byBook[book]!,
            prior('audio', note.id, book),
            tracksByBook[book] ??= await AssetStore(
              local,
              Directory('.'),
            ).audioTracks(book),
          ),
          'audio',
          note.id,
          book,
        );
      }
      for (final e in values.entries) {
        final slot = slots[e.key] as Map<String, dynamic>?;
        if (slot == null) {
          slots[e.key] = {
            'value': e.value,
            'synced': null,
            'revision': 0,
            'source': sources[e.key],
            'native': e.value,
          };
        } else {
          if (!sameMetadataValue(slot['native'], e.value)) {
            slot['value'] = e.value;
            slot['native'] = e.value;
          }
          slot['source'] = sources[e.key];
        }
      }
      for (final slot in slots.values) {
        final source = slot['source'] as Map?;
        if (source != null &&
            byBook[source['bookId']]?.id == slot['value']['itemId'] &&
            !values.containsKey(slot['value']['id']) &&
            slot['value']['deleted'] != true) {
          slot['value'] = {...slot['value'] as Map, 'deleted': true};
          slot['native'] = slot['value'];
        }
      }
    });
  });
  Future<bool> _apply(
    Map<String, dynamic> slot,
    Map<String, dynamic> next,
  ) async {
    final item = (await (catalog ?? LibraryRepository(local, namespace))
        .entries())[next['itemId']];
    final book = item?.sourceBookId;
    if (book == null || item!.state == 'removed') return true;
    var source = slot['source'] as Map?;
    if (source != null && source['bookId'] != book) {
      slot.remove('source');
      slot.remove('native');
      source = null;
    }
    final reading = ReadingLibrary(local);
    if (next['mediaType'] == 'book') {
      final id =
          source?['id'] as String? ?? uuid.v5(next['id'] as String, book);
      final raw = await reading.value('reading-note:$id');
      if (source != null) {
        final current = raw.isEmpty
            ? {...slot['native'] as Map, 'deleted': true}
            : _reader(
                ReadingNote.fromJson(raw),
                item.item,
                slot['native'] as Map?,
              );
        if (!sameMetadataValue(current, slot['native']) &&
            !sameMetadataValue(current, next)) {
          return false;
        }
      } else if (next['deleted'] == true) {
        return true;
      }
      if (next['deleted'] == true) {
        await reading.deleteNote(id);
      } else {
        final files = await local.db
            .customSelect(
              'SELECT sha256 FROM local_assets WHERE book_id=?',
              variables: [Variable(book)],
            )
            .get();
        final hash =
            files.firstOrNull?.read<String>('sha256') ??
            next['anchor']['hash'] as String? ??
            '';
        final anchor = next['anchor'] as Map, valid = anchor['hash'] == hash;
        await reading.saveNote(
          ReadingNote(
            id: id,
            bookId: book,
            hash: hash,
            bookTitle: item.item.title,
            chapterTitle: next['title'] as String,
            quote: next['quote'] as String,
            comment: next['text'] as String,
            color: next['color'] as String,
            updated: next['updatedAt'] as String,
            chapter: valid ? (anchor['chapter'] as num?)?.toInt() ?? -1 : -1,
            start: valid ? (anchor['start'] as num?)?.toInt() ?? 0 : 0,
            end: valid ? (anchor['end'] as num?)?.toInt() ?? 0 : 0,
            tags: List<String>.from(next['tags'] as List),
            characters: List<String>.from(next['characters'] as List),
          ),
        );
      }
      slot['source'] = {'kind': 'reader', 'id': id, 'bookId': book};
      slot['native'] = next;
    } else if (next['kind'] == 'audio') {
      final id =
              source?['id'] as String? ?? uuid.v5(next['id'] as String, book),
          row = await local.record(id);
      if (source != null &&
          row != null &&
          !sameMetadataValue(
            await _audio(row, item.item, slot['native'] as Map?),
            slot['native'],
          ) &&
          !sameMetadataValue(
            await _audio(row, item.item, slot['native'] as Map?),
            next,
          )) {
        return false;
      }
      if (next['deleted'] == true) {
        if (row != null) {
          await AudioJournal(local).put('audio_note', id, {
            ...row.payload!,
            'updatedAt': next['updatedAt'],
          });
          await AudioJournal(local).deleteNote(id);
        }
      } else {
        final tracks = await AssetStore(
          local,
          Directory('.'),
        ).audioTracks(book);
        if (tracks.isEmpty) return true;
        final anchor = next['anchor'] as Map,
            match = tracks
                .where((t) => t.hash == anchor['trackHash'])
                .firstOrNull;
        final ordinal = (anchor['trackIndex'] as num?)?.toInt();
        final track =
            match ??
            (ordinal != null && ordinal >= 0 && ordinal < tracks.length
                ? tracks[ordinal]
                : null);
        if (track == null) {
          return true; // Text remains available in the Obsidian notes view.
        }
        await AudioJournal(local).put('audio_note', id, {
          'bookId': book,
          'trackId': track.id,
          'positionMs': anchor['positionMs'] ?? 0,
          'kind': anchor['noteKind'] ?? 'thought',
          'title': next['title'],
          'text': next['text'],
          'at': row?.payload?['at'] ?? next['updatedAt'],
          'updatedAt': next['updatedAt'],
        });
      }
      slot['source'] = {'kind': 'audio', 'id': id, 'bookId': book};
      slot['native'] = next;
    }
    return true;
  }

  @override
  Future<void> receipts(List<dynamic> receipts) async {
    for (final r in receipts) {
      if (r is! Map ||
          !['applied', 'conflict'].contains(r['status']) ||
          r['record'] is! Map ||
          !validNoteValue(r['record']['entry']) ||
          r['record']['revision'] is! int ||
          r['record']['revision'] <= 0) {
        throw const FormatException(
          'Некорректное подтверждение заметки. Очередь сохранена.',
        );
      }
    }
    await super.receipts(receipts);
  }

  @override
  Future<void> receive(List<dynamic> records, int cursor) => mutate((
    state,
  ) async {
    final slots = state['slots'] as Map<String, dynamic>;
    if (cursor < (state['cursor'] as int)) {
      throw const FormatException('Курсор заметок откатился.');
    }
    for (final r in records) {
      if (r is! Map ||
          !validNoteValue(r['entry']) ||
          r['revision'] is! int ||
          r['revision'] <= 0 ||
          r['sequence'] is! int ||
          r['sequence'] <= 0 ||
          r['sequence'] > cursor) {
        throw const FormatException('Некорректная заметка. Курсор сохранён.');
      }
    }
    for (final raw in records) {
      final value = Map<String, dynamic>.from(raw['entry'] as Map),
          id = value['id'] as String,
          slot = slots[id] as Map<String, dynamic>?;
      if (slot != null &&
          (raw['revision'] as int) <= (slot['revision'] as int)) {
        continue;
      }
      if (slot != null &&
          !sameMetadataValue(slot['value'], slot['synced']) &&
          !sameMetadataValue(slot['value'], value)) {
        slot['conflict'] = raw;
        continue;
      }
      final next = {
        ...?slot,
        'value': value,
        'synced': value,
        'revision': raw['revision'],
      };
      if (!await _apply(next, value)) {
        slot!['conflict'] = raw;
        continue;
      }
      next.remove('operation');
      next.remove('conflict');
      slots[id] = next;
    }
    state['cursor'] = cursor;
  });
  @override
  Future<void> edit(String id, Map<String, dynamic> next) =>
      mutate((state) async {
        final slot = (state['slots'] as Map)[id] as Map<String, dynamic>?;
        if (slot == null || slot['conflict'] != null) {
          throw StateError('Сначала разрешите конфликт заметки.');
        }
        final changed = {
          ...slot['value'] as Map<String, dynamic>,
          ...next,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        };
        if (!validNoteValue(changed)) {
          throw const FormatException(
            'Проверьте размер заметки и метки; аудиозаметка должна содержать текст.',
          );
        }
        if (!await _apply(slot, changed)) {
          throw StateError('Заметка изменилась. Повторите синхронизацию.');
        }
        slot['value'] = changed;
      });
  @override
  Future<void> resolve(String id, {required bool useRemote}) =>
      mutate((state) async {
        final slot = (state['slots'] as Map)[id] as Map<String, dynamic>?,
            conflict = slot?['conflict'] as Map?;
        if (slot == null || conflict == null) return;
        if (useRemote) {
          final next = Map<String, dynamic>.from(conflict['entry'] as Map);
          if (!await _apply(slot, next)) {
            throw StateError('Заметка изменилась. Повторите синхронизацию.');
          }
          slot['value'] = next;
        }
        slot['synced'] = conflict['entry'];
        slot['revision'] = conflict['revision'];
        slot.remove('operation');
        slot.remove('conflict');
      });
}
