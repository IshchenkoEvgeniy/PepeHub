import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../data/repository.dart';
import '../media/asset_store.dart';
import 'book_formats.dart';
import 'reader_layout.dart';
import 'text_book.dart';
import 'pdf_support.dart';

class ReadingLibrary {
  final Repository repository;
  ReadingLibrary(this.repository);
  Future<Map<String, dynamic>> value(String key) async {
    final raw = await repository.meta(key);
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<Map<String, Map<String, dynamic>>> entries(String prefix) async {
    final rows = await repository.db
        .customSelect(
          'SELECT key,value FROM metadata WHERE key>=? AND key<?',
          variables: [Variable(prefix), Variable('$prefix\uffff')],
        )
        .get();
    return {
      for (final r in rows)
        if (r.read<String>('key').startsWith(prefix))
          r.read<String>('key').substring(prefix.length):
              jsonDecode(r.read<String>('value')) as Map<String, dynamic>,
    };
  }

  Future<void> update(String key, Map<String, dynamic> changes) =>
      repository.db.transaction(() async {
        await repository.setMeta(
          key,
          jsonEncode({...await value(key), ...changes}),
        );
      });

  /// One index per content hash; scanning never copies the source book.
  Future<void> index(
    AssetStore store,
    LocalAsset asset, {
    bool retry = false,
  }) async {
    final key = 'reading-index:${asset.hash}';
    final oldIndex = await value(key);
    if (!retry &&
        oldIndex.isNotEmpty &&
        oldIndex['needsCoverRefresh'] != true &&
        (bookFormat(asset.filename) == 'pdf' ||
            oldIndex['metadataVersion'] == 2) &&
        (bookFormat(asset.filename) != 'pdf' ||
            oldIndex['pdfCoverVersion'] == 1 ||
            oldIndex['error'] != null)) {
      return;
    }
    File? temporaryPdf;
    try {
      if (bookFormat(asset.filename) == 'pdf') {
        var source = File(asset.path);
        if (asset.bytes <= 0 || asset.bytes > 256 * 1024 * 1024) {
          throw const FormatException('PDF превышает 256 МБ');
        }
        if (asset.path.startsWith('content:')) {
          // SAF is sequential. Use one temporary seekable file for PDFium,
          // then keep only the thumbnail, not a second copy of the library.
          await store.directory.create(recursive: true);
          source = temporaryPdf = File(
            p.join(store.directory.path, 'pdf-cover-${uuid.v4()}.partial'),
          );
          final sink = source.openWrite();
          var received = 0;
          try {
            await for (final chunk in SafAudioFile(
              asset.path,
              asset.filename,
              asset.bytes,
            ).openRead()) {
              received += chunk.length;
              if (received > asset.bytes) {
                throw StateError('Размер PDF изменился');
              }
              sink.add(chunk);
            }
          } finally {
            await sink.close();
          }
          if (received != asset.bytes) {
            throw StateError('PDF прочитан не полностью');
          }
        }
        final digest = await sha256.bind(source.openRead()).first;
        if (digest.toString() != asset.hash) {
          throw StateError('Файл изменился. Обновите папку книг.');
        }
        final pdf = await openLocalPdf(source.path);
        try {
          final bytes = await pdfCover(pdf);
          final dir = Directory(p.join(store.directory.path, 'reading-covers'));
          await dir.create(recursive: true);
          final cover = File(p.join(dir.path, '${asset.hash}.png'));
          await cover.writeAsBytes(bytes, flush: true);
          await update(key, {
            'title': p.basenameWithoutExtension(asset.filename),
            'cover': cover.path,
            'pdfPages': pdf.pages.length,
            'pdfCoverVersion': 1,
            'needsCoverRefresh': false,
            'error': null,
          });
          // Migrate the original PDF viewer's page-only bookmark once.
          if (await repository.meta('reader:${asset.hash}') == null) {
            final old = int.tryParse(
              await repository.meta('pdf:${asset.hash}') ?? '',
            );
            if (old != null) {
              await update('reader:${asset.hash}', {
                'chapter': old.clamp(1, pdf.pages.length) - 1,
                'textOffset': 0,
              });
            }
          }
        } finally {
          await pdf.dispose();
        }
        return;
      }
      final Uint8List bytes;
      if (asset.path.startsWith('content:')) {
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in SafAudioFile(
          asset.path,
          asset.filename,
          asset.bytes,
        ).openRead()) {
          if (buffer.length + chunk.length > 64 * 1024 * 1024) {
            throw const FormatException('Книга превышает 64 МБ');
          }
          buffer.add(chunk);
        }
        bytes = buffer.takeBytes();
      } else {
        final file = File(asset.path);
        if (await file.length() > 64 * 1024 * 1024) {
          throw const FormatException('Книга превышает 64 МБ');
        }
        bytes = await file.readAsBytes();
      }
      final name = asset.filename;
      if (sha256.convert(bytes).toString() != asset.hash) {
        throw StateError('Файл изменился. Обновите папку книг.');
      }
      final book = await Isolate.run(() => parseTextBook(bytes, name));
      String? coverPath;
      if (book.cover != null && book.cover!.isNotEmpty) {
        final dir = Directory(p.join(store.directory.path, 'reading-covers'));
        await dir.create(recursive: true);
        final cover = File(p.join(dir.path, '${asset.hash}.image'));
        await cover.writeAsBytes(book.cover!, flush: true);
        coverPath = cover.path;
      }
      final document = ReaderDocument(book);
      if (await repository.meta('reader:${asset.hash}') == null) {
        final recovered = await value(
          'reading-recovered-position:${asset.hash}',
        );
        final absolute = (recovered['position'] as num?)?.toInt();
        if (absolute != null && document.length > 0) {
          final place = document.locate(
            (absolute / document.length).clamp(0.0, 1.0),
          );
          await update('reader:${asset.hash}', {
            'chapter': place.chapter,
            'textOffset': place.offset,
          });
        }
      }
      await repository.setMeta(
        key,
        jsonEncode({
          ...book.metadata,
          'metadataVersion': 2,
          'title': book.title,
          'authors': book.authors,
          'series': book.series,
          'seriesNumber': book.seriesNumber,
          'description': book.description,
          'cover': coverPath,
          'chapters': [for (final c in book.chapters) c.title],
          'starts': document.starts,
          'lengths': [for (final t in document.texts) t.length],
          'paragraphStarts': [
            for (final chapter in book.chapters)
              paragraphOffsets(chapter.paragraphs),
          ],
          'length': document.length,
        }),
      );
    } catch (e) {
      // Retain a usable index when a disconnected folder makes a retry fail.
      await update(key, {'error': '$e'});
      if (retry) rethrow;
    } finally {
      if (temporaryPdf != null && await temporaryPdf.exists()) {
        await temporaryPdf.delete();
      }
    }
  }

  Future<List<ReadingNote>> notes({String? hash, Set<String>? bookIds}) async {
    final all = await entries('reading-note:');
    final result = all.values
        .map(ReadingNote.fromJson)
        .where(
          (n) =>
              (hash == null || n.hash == hash) &&
              (bookIds == null || bookIds.contains(n.bookId)),
        )
        .toList();
    result.sort((a, b) => b.updated.compareTo(a.updated));
    return result;
  }

  static Map<String, dynamic> effective(
    Map<String, dynamic> original,
    Map<String, dynamic> preferences, [
    Map<String, dynamic> dates = const {},
  ]) => {
    ...original,
    ...dates,
    ...Map<String, dynamic>.from(preferences['overrides'] as Map? ?? {}),
  };

  Future<Map<String, dynamic>> bookInfo(
    LibraryRecord book,
    String? hash,
  ) async => effective(
    {...?book.payload, if (hash != null) ...await value('reading-index:$hash')},
    await value('reading-book:${book.id}'),
    await value('reading-dates:${book.id}'),
  );

  Future<void> saveDetails(
    String bookId,
    Map<String, dynamic> overrides,
  ) async {
    final title = (overrides['title'] as String? ?? '').trim();
    if (title.isEmpty) throw ArgumentError('Укажите название книги');
    final dates = {...await value('reading-dates:$bookId'), ...overrides};
    final start = DateTime.tryParse(dates['startedAt'] as String? ?? '')
            ?.toLocal(),
        end = DateTime.tryParse(dates['finishedAt'] as String? ?? '')
            ?.toLocal();
    if (start != null &&
        end != null &&
        DateTime(
          end.year,
          end.month,
          end.day,
        ).isBefore(DateTime(start.year, start.month, start.day))) {
      throw ArgumentError('Завершение не может быть раньше начала');
    }
    await update('reading-book:$bookId', {
      'overrides': {...overrides, 'title': title},
    });
  }

  Future<void> saveNote(ReadingNote note) =>
      repository.setMeta('reading-note:${note.id}', jsonEncode(note.toJson()));
  Future<void> deleteNote(String id) => repository.db.customStatement(
    'DELETE FROM metadata WHERE key=?',
    ['reading-note:$id'],
  );
}

List<int> paragraphOffsets(List<String> paragraphs) {
  var offset = 0;
  return [
    for (final text in paragraphs)
      (() {
        final start = offset;
        offset += text.length + 2;
        return start;
      })(),
  ];
}

class ReadingNote {
  final String id,
      bookId,
      hash,
      bookTitle,
      chapterTitle,
      quote,
      comment,
      color,
      updated;
  final int chapter, start, end;
  final List<String> tags, characters;
  ReadingNote({
    required this.id,
    required this.bookId,
    required this.hash,
    required this.bookTitle,
    required this.chapterTitle,
    required this.quote,
    required this.comment,
    required this.color,
    required this.updated,
    required this.chapter,
    required this.start,
    required this.end,
    this.tags = const [],
    this.characters = const [],
  });
  factory ReadingNote.fromJson(Map<String, dynamic> j) => ReadingNote(
    id: j['id'] as String,
    bookId: j['bookId'] as String,
    hash: j['hash'] as String,
    bookTitle: j['bookTitle'] as String,
    chapterTitle: j['chapterTitle'] as String,
    quote: j['quote'] as String,
    comment: j['comment'] as String,
    color: j['color'] as String,
    updated: j['updated'] as String,
    chapter: j['chapter'] as int,
    start: j['start'] as int,
    end: j['end'] as int,
    tags: normalizeNoteLabels((j['tags'] as List? ?? []).whereType<String>()),
    characters: normalizeNoteLabels(
      (j['characters'] as List? ?? []).whereType<String>(),
    ),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'bookId': bookId,
    'hash': hash,
    'bookTitle': bookTitle,
    'chapterTitle': chapterTitle,
    'quote': quote,
    'comment': comment,
    'color': color,
    'updated': updated,
    'chapter': chapter,
    'start': start,
    'end': end,
    'tags': tags,
    'characters': characters,
  };
}

List<String> normalizeNoteLabels(Iterable<String> values, {int? limit = 40}) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in values) {
    final value = raw.trim().substring(0, raw.trim().length.clamp(0, 80));
    if (value.isNotEmpty && seen.add(value.toLowerCase())) result.add(value);
    if (limit != null && result.length >= limit) break;
  }
  return result;
}

List<ReadingNote> filterReadingNotes(
  Iterable<ReadingNote> notes, {
  String query = '',
  String? color,
  String? tag,
  String? character,
}) {
  final q = query.trim().toLowerCase();
  bool has(List<String> values, String? value) =>
      value == null ||
      values.any((v) => v.toLowerCase() == value.toLowerCase());
  return notes
      .where(
        (n) =>
            (color == null || n.color == color) &&
            has(n.tags, tag) &&
            has(n.characters, character) &&
            '${n.quote} ${n.comment} ${n.bookTitle} ${n.chapterTitle} ${n.tags.join(' ')} ${n.characters.join(' ')}'
                .toLowerCase()
                .contains(q),
      )
      .toList();
}

double readingFraction(
  Map<String, dynamic> index,
  Map<String, dynamic> position,
) {
  if (position.isEmpty) return 0;
  if ((index['length'] as num? ?? 0) <= 0) {
    final pages = (index['pdfPages'] as num?)?.toInt() ?? 0;
    if (pages <= 0) return 0;
    return position['pdfFinished'] == true
        ? 1
        : (((position['chapter'] as num? ?? 0)) / pages).clamp(0.0, 1.0);
  }
  final starts = (index['starts'] as List?) ?? [];
  if (starts.isEmpty) return 0;
  final chapter = ((position['chapter'] as num?)?.toInt() ?? 0).clamp(
    0,
    starts.length - 1,
  );
  var offset = (position['textOffset'] as num?)?.toInt();
  if (offset == null) {
    final paragraphs =
        (index['paragraphStarts'] as List? ?? [])[chapter] as List;
    final paragraph = ((position['paragraph'] as num?)?.toInt() ?? 0).clamp(
      0,
      paragraphs.length - 1,
    );
    offset =
        (paragraphs[paragraph] as num).toInt() +
        ((position['offset'] as num?)?.toInt() ?? 0);
  }
  return (((starts[chapter] as num) + offset) / (index['length'] as num)).clamp(
    0.0,
    1.0,
  );
}
