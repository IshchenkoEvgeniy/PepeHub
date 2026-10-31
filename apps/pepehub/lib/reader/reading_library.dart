import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../data/database_schema.dart';
import '../data/repository.dart';
import '../media/asset_store.dart';
import '../media/verified_stream_copy.dart';
import 'book_formats.dart';
import 'epub.dart' show EpubBook;
import 'reader_layout.dart';
import 'reader_rebase.dart';
import 'text_book.dart';
import 'pdf_support.dart';

// Keep the isolate closure outside instance methods so it cannot capture a DB.
Future<({EpubBook book, EpubBook? previous, EpubBook? legacy})>
_parseIndexedText(
  String sourcePath,
  String name,
  String hash,
  TransferableTypedData? transferred,
  bool refreshTxt,
  int sourceLayout,
) => Isolate.run(() {
  final Uint8List bytes;
  if (transferred != null) {
    bytes = transferred.materialize().asUint8List();
  } else {
    final file = File(sourcePath);
    if (file.lengthSync() > 64 * 1024 * 1024) {
      throw const FormatException('Книга превышает 64 МБ');
    }
    bytes = file.readAsBytesSync();
  }
  if (bytes.length > 64 * 1024 * 1024) {
    throw const FormatException('Книга превышает 64 МБ');
  }
  if (sha256.convert(bytes).toString() != hash) {
    throw StateError('Файл изменился. Обновите папку книг.');
  }
  return (
    book: parseTextBook(bytes, name),
    previous: refreshTxt && sourceLayout != currentBookLayout
        ? parseTextBook(
            bytes,
            name,
            layout: sourceLayout == 1 ? 2 : sourceLayout,
          )
        : null,
    legacy: refreshTxt && sourceLayout == 1
        ? parseTextBook(bytes, name, legacyProjection: true, layout: 2)
        : null,
  );
});

class ReadingLibrary {
  // Must match the reading_notes_* expression indexes in the schema.
  static const _noteJson = SchemaSql.noteJson;
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
    // One foreign or damaged value under a shared prefix (for example a plain
    // setting stored as "reader:something") must not hide the whole library.
    final result = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final key = r.read<String>('key');
      if (!key.startsWith(prefix)) continue;
      try {
        final value = jsonDecode(r.read<String>('value'));
        if (value is Map<String, dynamic>) {
          result[key.substring(prefix.length)] = value;
        }
      } on FormatException {
        /* Not a JSON record of this collection. */
      }
    }
    return result;
  }

  /// Reads the compact projection; full paragraph indexes are reader-only.
  Future<Map<String, Map<String, dynamic>>> shelfIndex(
    Map<String, Map<String, dynamic>> positions,
  ) async {
    final rows = await repository.db
        .customSelect('SELECT key,value,text_offset FROM reading_shelf_v1')
        .get();
    final result = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final hash = row.read<String>('key').substring('reading-index:'.length);
      final value = jsonDecode(row.read<String>('value'));
      if (value is! Map<String, dynamic>) continue;
      result[hash] = value;
      final saved = positions[hash];
      if (saved != null && saved.isNotEmpty && saved['textOffset'] == null) {
        saved['textOffset'] = row.read<int>('text_offset');
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> shelfInfo(String hash) async {
    final row = await repository.db
        .customSelect(
          'SELECT value FROM reading_shelf_v1 WHERE key=?',
          variables: [Variable('reading-index:$hash')],
        )
        .getSingleOrNull();
    return row == null
        ? {}
        : jsonDecode(row.read<String>('value')) as Map<String, dynamic>;
  }

  Future<Map<String, Map<String, dynamic>>> statisticsSessions({
    String? bookId,
  }) async {
    final rows = await repository.db
        .customSelect(
          'SELECT key,value FROM reading_statistics_sessions_v1 ${bookId == null ? '' : 'WHERE book_id=?'}',
          variables: [if (bookId != null) Variable(bookId)],
        )
        .get();
    final values = [
      for (final row in rows)
        (row.read<String>('key'), row.read<String>('value')),
    ];
    return Isolate.run(
      () => {
        for (final (key, raw) in values)
          key.substring('reading-session:'.length):
              jsonDecode(raw) as Map<String, dynamic>,
      },
    );
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
    final oldIndex = await shelfInfo(asset.hash);
    if (!retry &&
        oldIndex.isNotEmpty &&
        oldIndex['needsCoverRefresh'] != true &&
        (bookFormat(asset.filename) != 'txt' ||
            oldIndex['layoutVersion'] == currentBookLayout) &&
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
        String? copiedHash;
        if (asset.bytes <= 0 || asset.bytes > 256 * 1024 * 1024) {
          throw const FormatException('PDF превышает 256 МБ');
        }
        if (asset.path.startsWith('content:')) {
          Map<String, dynamic>? preview;
          try {
            preview = await audioFolderChannel.invokeMapMethod<String, dynamic>(
              'pdfPreview',
              {'uri': asset.path, 'hash': asset.hash, 'bytes': asset.bytes},
            );
          } catch (_) {
            /* Non-seekable providers use the verified copy below. */
          }
          final png = preview?['png'], pages = preview?['pages'];
          if (png is Uint8List &&
              png.length <= 2 * 1024 * 1024 &&
              pages is int &&
              pages > 0 &&
              pages <= 20000) {
            await _storePdfCover(store, asset, png, pages);
            return;
          }
          // SAF is sequential. Use one temporary seekable file for PDFium,
          // then keep only the thumbnail, not a second copy of the library.
          await store.directory.create(recursive: true);
          source = temporaryPdf = File(
            p.join(store.directory.path, 'pdf-cover-${uuid.v4()}.partial'),
          );
          final copied = await copyVerifiedStream(
            SafAudioFile(asset.path, asset.filename, asset.bytes).openRead(),
            source,
            expectedBytes: asset.bytes,
          );
          copiedHash = copied.hash;
        }
        final pdfPath = source.path;
        final digest =
            copiedHash ??
            await Isolate.run(
              () async => (await sha256.bind(File(pdfPath).openRead()).first)
                  .toString(),
            );
        if (digest != asset.hash) {
          throw StateError('Файл изменился. Обновите папку книг.');
        }
        final pdf = await openLocalPdf(source.path);
        try {
          await _storePdfCover(
            store,
            asset,
            await pdfCover(pdf),
            pdf.pages.length,
          );
        } finally {
          await pdf.dispose();
        }
        return;
      }
      final name = asset.filename, hash = asset.hash, sourcePath = asset.path;
      // Platform channels must stay in the root isolate. Transfer their bytes
      // without copying; regular files are read directly by the parsing worker.
      TransferableTypedData? transferred;
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
        transferred = TransferableTypedData.fromList([buffer.takeBytes()]);
      }
      // Refresh stale TXT navigation in the existing sequential indexing worker.
      // Rebase saved anchors before replacing starts; shelf reads stay compact.
      final refreshTxt =
          bookFormat(name) == 'txt' &&
          oldIndex.isNotEmpty &&
          oldIndex['layoutVersion'] != currentBookLayout;
      final sourceLayout = refreshTxt
          ? int.tryParse(
                  await repository.meta('reader-layout-version:$hash') ?? '',
                ) ??
                ((await value('reader:$hash'))['layoutVersion'] == 2 ? 2 : 1)
          : currentBookLayout;
      final parsed = await _parseIndexedText(
        sourcePath,
        name,
        hash,
        transferred,
        refreshTxt,
        sourceLayout,
      );
      final book = parsed.book;
      String? coverPath;
      if (book.cover != null && book.cover!.isNotEmpty) {
        final dir = Directory(p.join(store.directory.path, 'reading-covers'));
        await dir.create(recursive: true);
        final cover = File(p.join(dir.path, '${asset.hash}.image'));
        await cover.writeAsBytes(book.cover!, flush: true);
        coverPath = cover.path;
      }
      final document = ReaderDocument(book);
      await repository.db.transaction(() async {
        if (refreshTxt) {
          final previous = parsed.previous == null
              ? document
              : ReaderDocument(parsed.previous!);
          await migrateReaderLayout(
            this,
            hash,
            document,
            () async => parsed.legacy == null
                ? previous
                : ReaderDocument(parsed.legacy!),
            previous: () async => previous,
            sourceLayout: (_) async => previous,
          );
        }
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
            'layoutVersion': currentBookLayout,
            'title': book.title,
            'authors': book.authors,
            'series': book.series,
            'seriesNumber': book.seriesNumber,
            'description': book.description,
            'cover': coverPath ?? oldIndex['cover'],
            'chapters': [for (final c in book.chapters) c.title],
            'starts': document.starts,
            'lengths': [for (final t in document.texts) t.length],
            'paragraphStarts': [
              for (final chapter in book.chapters)
                paragraphOffsets(
                  chapter.paragraphs,
                  separator: chapter.paragraphSeparator,
                ),
            ],
            'length': document.length,
          }),
        );
      });
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

  Future<void> _storePdfCover(
    AssetStore store,
    LocalAsset asset,
    Uint8List bytes,
    int pages,
  ) async {
    final dir = Directory(p.join(store.directory.path, 'reading-covers'));
    await dir.create(recursive: true);
    final cover = File(p.join(dir.path, '${asset.hash}.png'));
    await cover.writeAsBytes(bytes, flush: true);
    await update('reading-index:${asset.hash}', {
      'title': p.basenameWithoutExtension(asset.filename),
      'cover': cover.path,
      'pdfPages': pages,
      'pdfCoverVersion': 1,
      'needsCoverRefresh': false,
      'error': null,
    });
    if (await repository.meta('reader:${asset.hash}') == null) {
      final old = int.tryParse(
        await repository.meta('pdf:${asset.hash}') ?? '',
      );
      if (old != null) {
        await update('reader:${asset.hash}', {
          'chapter': old.clamp(1, pages) - 1,
          'textOffset': 0,
        });
      }
    }
  }

  Future<List<ReadingNote>> notes({String? hash, Set<String>? bookIds}) async {
    if (bookIds?.isEmpty == true) return [];
    final rows = await repository.db
        .customSelect(
          "SELECT value FROM metadata WHERE key>='reading-note:' AND key<'reading-note;' "
          "${hash == null ? '' : "AND json_extract($_noteJson,'\$.hash')=? "}"
          "${bookIds == null ? '' : "AND json_extract($_noteJson,'\$.bookId') IN (${List.filled(bookIds.length, '?').join(',')})"}",
          variables: [
            if (hash != null) Variable(hash),
            if (bookIds != null)
              for (final id in bookIds) Variable(id),
          ],
        )
        .get();
    final result = [
      for (final row in rows)
        ReadingNote.fromJson(
          jsonDecode(row.read<String>('value')) as Map<String, dynamic>,
        ),
    ];
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
    {...?book.payload, if (hash != null) ...await shelfInfo(hash)},
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

List<int> paragraphOffsets(
  List<String> paragraphs, {
  String separator = '\n\n',
}) {
  var offset = 0;
  return [
    for (final text in paragraphs)
      (() {
        final start = offset;
        offset += text.length + separator.length;
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
    final chapters = index['paragraphStarts'] as List? ?? [];
    final paragraphs = chapter < chapters.length && chapters[chapter] is List
        ? chapters[chapter] as List
        : const [];
    final paragraph = paragraphs.isEmpty
        ? 0
        : ((position['paragraph'] as num?)?.toInt() ?? 0).clamp(
            0,
            paragraphs.length - 1,
          );
    // Older indexes may lack this chapter. Preserve its known location until reindexing.
    offset =
        (paragraphs.isEmpty ? 0 : (paragraphs[paragraph] as num).toInt()) +
        ((position['offset'] as num?)?.toInt() ?? 0);
  }
  return (((starts[chapter] as num) + offset) / (index['length'] as num)).clamp(
    0.0,
    1.0,
  );
}

/// 0.23.0 kept the PDF page mode as plain text under "reader:pdf-mode". The
/// "reader:" prefix holds JSON positions, so the value moves to its own key.
Future<void> migrateLegacyPdfMode(Repository repository) async {
  const legacyKey = 'reader:pdf-mode';
  final legacy = await repository.meta(legacyKey);
  if (legacy == null) return;
  await repository.db.transaction(() async {
    if (await repository.meta('pdf-reader-mode') == null) {
      await repository.setMeta('pdf-reader-mode', legacy);
    }
    await repository.db.customStatement('DELETE FROM metadata WHERE key=?', [
      legacyKey,
    ]);
  });
}
