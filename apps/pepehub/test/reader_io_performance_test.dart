import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/verified_stream_copy.dart';
import 'package:pepehub/reader/pdf_search_page.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_log.dart';
import 'package:pepehub/reader/reading_plan.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/reader/text_book.dart';

class ChunkedAudio extends XFile {
  final Uint8List bytes;
  ChunkedAudio(this.bytes) : super('virtual.mp3');
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final finish = end ?? bytes.length;
    for (var at = start ?? 0; at < finish; at += 65536) {
      yield Uint8List.sublistView(bytes, at, (at + 65536).clamp(0, finish));
    }
  }
}

class CountingTracks extends AssetStore {
  int reads = 0;
  CountingTracks(super.repository, super.directory);
  @override
  Future<List<LocalAsset>> audioTracks(
    String bookId, {
    String? editionId,
    bool firstOnly = false,
  }) {
    reads++;
    return super.audioTracks(
      bookId,
      editionId: editionId,
      firstOnly: firstOnly,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('large RTF retains paragraph style offsets in one pass', () {
    final source = StringBuffer(r'{\rtf1\ansi ');
    for (var i = 0; i < 5000; i++) {
      source.write('{\\b word-$i}\\par\\par ');
    }
    source.write('}');
    final book = parseTextBook(
      Uint8List.fromList(utf8.encode(source.toString())),
      'large.rtf',
    );
    final paragraphs = book.chapters.expand((c) => c.paragraphs).toList();
    expect(paragraphs, hasLength(5000));
    for (final i in [0, 2500, 4999]) {
      expect(paragraphs[i], contains('word-$i'));
      final chapter = book.chapters.single;
      final style = chapter.markup[i];
      expect(style.bold, isTrue);
      expect(chapter.text.substring(style.start, style.end), 'word-$i');
    }
  });
  test(
    'a large stream chunk remains cancellable between bounded worker batches',
    () async {
      final dir = await Directory.systemTemp.createTemp('pepe-copy-batches-');
      try {
        var checks = 0;
        final target = File('${dir.path}/copy.partial');
        await expectLater(
          copyVerifiedStream(
            Stream.value(Uint8List(4 * 1024 * 1024)),
            target,
            expectedBytes: 4 * 1024 * 1024,
            check: () {
              if (++checks == 3) throw StateError('cancel');
            },
          ),
          throwsStateError,
        );
        expect(await target.length(), lessThanOrEqualTo(1024 * 1024));
        // An acknowledgement of abort means the worker released the file.
        await target.rename('${dir.path}/closed.partial');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test('checkpoints skip unrelated history and preserve complete root/day recovery events', () async {
    final log = <String>[];
    await runZoned(
      () async {
        final root = await Directory.systemTemp.createTemp('pepe-log-scope-');
        final db = AppDatabase(NativeDatabase.memory(logStatements: true));
        try {
          final repo = Repository(db), library = ReadingLibrary(Repository(db));
          final selected = <String, dynamic>{
            'id': 'selected',
            'bookId': 'book',
            'startedAt': '2026-10-31T12:00:00Z',
            'endedAt': '2026-10-31T12:01:00Z',
            'spans': [],
            'events': [
              {'kind': 'jump', 'position': 15},
            ],
          };
          await db.transaction(() async {
            for (var i = 0; i < 3000; i++) {
              await repo.setMeta(
                'reading-session:old-$i',
                jsonEncode({
                  ...selected,
                  'id': 'old-$i',
                  'bookId': i.isEven ? 'book' : 'other',
                  'startedAt': '2025-01-01T12:00:00Z',
                }),
              );
            }
          });
          log.clear();
          await ReadingLog(repo).export(selected);
          expect(
            log.where(
              (s) =>
                  s.contains('reading_statistics_sessions_v1') ||
                  s.contains('FROM records'),
            ),
            isEmpty,
          );
          await repo.setMeta(
            'reading-library-root:test',
            jsonEncode({
              'path': root.path,
              'bookIds': ['book'],
            }),
          );
          await repo.setMeta('reading-session:selected', jsonEncode(selected));
          await repo.setMeta(
            'reading-session:foreign',
            jsonEncode({...selected, 'id': 'foreign', 'bookId': 'other'}),
          );
          await db.customStatement(
            'INSERT INTO local_assets VALUES(?,?,?,?,?,?)',
            ['asset', 'book', 'b.txt', 'unused', 'hash', 12],
          );
          await repo.setMeta(
            'reading-index:hash',
            jsonEncode({
              'length': 42,
              'paragraphStarts': [
                [0, 12, 24],
              ],
            }),
          );
          log.clear();
          await ReadingLog(repo).export(selected);
          final day = DateTime.parse(selected['startedAt'] as String)
              .toLocal()
              .toIso8601String()
              .substring(0, 10);
          final packet = jsonDecode(
            await File(
              '${root.path}/.pepehub/reading/logs/$day/reading-$day.json',
            ).readAsString(),
          );
          expect((packet['sessions'] as List).map((s) => s['id']), [
            'selected',
          ]);
          expect(packet['sessions'][0]['events'], selected['events']);
          expect(packet['books'][0]['reading-index']['paragraphStarts'], [
            [0, 12, 24],
          ]);
          expect(
            log.any(
              (s) => s.contains('s.start_ms>=?') && s.contains('s.start_ms<?'),
            ),
            isTrue,
          );
          await expectLater(ReadingPlans(repo).load('book'), throwsStateError);
          await repo.put('book', 'book', {'title': 'Book', 'format': 'txt'});
          final data = await ReadingPlans(repo).load('book');
          expect(data.length, 42);
          expect(data.sessions.length, 1501);
          expect(
            data.sessions.every(
              (s) => s['bookId'] == 'book' && !s.containsKey('events'),
            ),
            isTrue,
          );
          expect(
            (await library.value('reading-session:selected'))['events'],
            selected['events'],
          );
          expect(await ReadingLog(repo).exportAll(bookId: 'book'), 2);
        } finally {
          await db.close();
          await root.delete(recursive: true);
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => log.add(line),
      ),
    );
  });

  test('large streamed audio import throttles progress, preserves hashes and detects same-size corruption', () async {
    final dir = await Directory.systemTemp.createTemp('pepe-import-worker-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final bytes = Uint8List(32 * 1024 * 1024)..setAll(0, 'ID3'.codeUnits);
      final source = ChunkedAudio(bytes),
          store = AssetStore(Repository(db), Directory('${dir.path}/assets'));
      final progress = <int>[];
      final watch = Stopwatch()..start();
      final asset = await store.importAudioBook(
        [source],
        title: 'Large',
        onProgress: (done, total) {
          progress.add(done);
          expect(total, bytes.length);
        },
      );
      watch.stop();
      expect(progress.last, bytes.length);
      expect(
        progress.length,
        lessThanOrEqualTo(watch.elapsedMilliseconds ~/ 100 + 3),
      );
      final actual = await File(asset.path).readAsBytes();
      expect(sha256.convert(actual), sha256.convert(bytes));
      actual[20] = 1;
      await File(asset.path).writeAsBytes(actual, flush: true);
      expect(await File(asset.path).length(), bytes.length);
      await expectLater(
        store.importAudioBook([source], title: 'Again'),
        throwsStateError,
      );
      expect(await Repository(db).records('book'), hasLength(1));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('single-line TXT adds chapters and paragraphs without moving UTF-16 anchors or quotes', () async {
    const source =
        'Название\nГлава 1\n  Первая строка.\n  Вторая строка.\nГлава 2\n  Третья строка.';
    final bytes = Uint8List.fromList(utf8.encode(source));
    final before = ReaderDocument(parseTextBook(bytes, 'book.txt', layout: 5));
    final after = ReaderDocument(parseTextBook(bytes, 'book.txt'));
    expect(after.book.chapters.length, 3);
    expect(after.book.chapters[1].paragraphs.length, greaterThan(2));
    expect(after.texts.join(), before.texts.join());
    expect(after.length, before.length);
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), library = ReadingLibrary(Repository(db));
      final start = before.texts.single.indexOf('Первая'),
          end = before.texts.single.indexOf('\nГлава 2');
      final quote = before.texts.single.substring(start, end);
      await repo.setMeta('reader-layout-version:hash', '5');
      await library.update('reader:hash', {'chapter': 0, 'textOffset': start});
      await library.update('reading-note:n', {
        'id': 'n',
        'bookId': 'book',
        'hash': 'hash',
        'chapter': 0,
        'start': start,
        'end': end,
        'quote': quote,
        'comment': 'Сохранить',
      });
      await migrateReaderLayout(
        library,
        'hash',
        after,
        () async => before,
        sourceLayout: (_) async => before,
      );
      final position = await library.value('reader:hash'),
          note = await library.value('reading-note:n');
      expect(position['chapter'], 1);
      expect(
        after.texts[note['chapter'] as int].substring(
          note['start'] as int,
          note['end'] as int,
        ),
        quote,
      );
      expect(note['quote'], quote);
      expect(note['comment'], 'Сохранить');
      final place = after.paragraphAt(
        position['chapter'] as int,
        position['textOffset'] as int,
      );
      expect(place.paragraph, greaterThan(0));
    } finally {
      await db.close();
    }
  });

  test('PDF search reuses 1000 page texts and evicts only beyond its bounded budget', () async {
    final cache = PdfSearchTextCache();
    var loads = 0;
    for (var pass = 0; pass < 2; pass++) {
      for (var page = 1; page <= 1000; page++) {
        expect(
          await cache.page(page, () async {
            loads++;
            return 'text $page';
          }),
          contains('text'),
        );
      }
    }
    expect(loads, 1000);
    expect(cache.cachedPages, 1000);
    cache.close();
    final small = PdfSearchTextCache(maxCharacters: 8, maxPages: 2);
    await small.page(1, () async => '12345');
    await small.page(2, () async => '67890');
    expect(small.cachedPages, 1);
    small.close();
  });

  test('Android PDF cover result avoids a temporary PDF and retains the legacy bookmark', () async {
    final root = await Directory.systemTemp.createTemp(
      'pepe-native-pdf-preview-',
    );
    final db = AppDatabase(NativeDatabase.memory());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    try {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      final picture = recorder.endRecording(),
          image = await pictureImage(picture);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      var previews = 0;
      messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
        expect(call.method, 'pdfPreview');
        previews++;
        expect((call.arguments as Map)['hash'], 'a' * 64);
        return {'png': png!.buffer.asUint8List(), 'pages': 10};
      });
      final repo = Repository(db), store = AssetStore(Repository(db), root);
      final asset = LocalAsset(
        id: 'pdf',
        bookId: 'book',
        filename: 'book.pdf',
        path: 'content://books/pdf',
        hash: 'a' * 64,
        bytes: 123,
      );
      await repo.setMeta('pdf:${asset.hash}', '7');
      await ReadingLibrary(repo).index(store, asset, retry: true);
      expect(previews, 1);
      expect(
        (await ReadingLibrary(repo).shelfInfo(asset.hash))['pdfPages'],
        10,
      );
      expect(
        (await ReadingLibrary(repo).value('reader:${asset.hash}'))['chapter'],
        6,
      );
      expect(
        await root.list().where((f) => f.path.endsWith('.partial')).isEmpty,
        isTrue,
      );
    } finally {
      messenger.setMockMethodCallHandler(audioFolderChannel, null);
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test(
    'root listing uses indexed key ranges in a large metadata catalog',
    () async {
      final log = <String>[];
      await runZoned(
        () async {
          final db = AppDatabase(NativeDatabase.memory(logStatements: true));
          try {
            final repo = Repository(db),
                assets = AssetStore(Repository(db), Directory('unused'));
            await db.transaction(() async {
              for (var i = 0; i < 3000; i++) {
                await repo.setMeta('unrelated:$i', '{}');
              }
            });
            log.clear();
            expect(await AudioRoots(assets).list(), isEmpty);
            expect(await ReadingRoots(assets).list(), isEmpty);
            expect(log.join(), isNot(contains(' LIKE ')));
            expect(log.join(), contains("key>='audio-library-root:'"));
            expect(log.join(), contains("key>='reading-library-root:'"));
          } finally {
            await db.close();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => log.add(line),
        ),
      );
    },
  );

  test('reconnecting 100 split audiobooks as 50 part groups keeps track queries linear', () async {
    final root = await Directory.systemTemp.createTemp('pepe-parts-scale-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db),
          store = CountingTracks(
            Repository(db),
            Directory('${root.path}/cache'),
          );
      final files = <XFile>[], ids = <String>[];
      for (var i = 0; i < 100; i++) {
        final file = File('${root.path}/track-$i.mp3');
        await file.writeAsBytes('ID30123456789'.codeUnits);
        files.add(XFile(file.path));
        ids.add(
          (await store.connectAudioFolder(
            [files.last],
            root: '${root.path}#old=$i',
            title: 'Part $i',
          )).bookId,
        );
      }
      await repo.setMeta(
        audioRootKey(root.path),
        jsonEncode({
          'root': root.path,
          'title': 'Root',
          'mode': 'files',
          'bookIds': ids,
        }),
      );
      final drafts = [
        for (var i = 0; i < 50; i++)
          AudioBookDraft('pair-$i', 'Pair $i', [
            files[i * 2],
            files[i * 2 + 1],
          ]),
      ];
      store.reads = 0;
      expect(
        await connectAudioCatalog(
          store,
          AudioFolder('Root', files, root: root.path),
          drafts,
          mode: 'parts',
        ),
        50,
      );
      expect(store.reads, lessThan(500));
      expect((await AudioRoots(store).list()).single.bookIds, hasLength(50));
      expect(await repo.meta('library-catalog-v1'), isNull);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}

Future<ui.Image> pictureImage(ui.Picture picture) => picture.toImage(4, 4);
