import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/database_files.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_artwork.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_statistics_data.dart';
import 'package:pepehub/reader/statistics_history.dart';
import 'package:pepehub/ui/statistics_management_page.dart';
import 'package:pepehub/ui/statistics_hub_page.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'video_player_tools_widget_test.dart' show ready;

LibraryEntry card(String title) => LibraryEntry(
  personalLibraryItem('card', 'book', {
    'title': title,
    'status': 'finished',
    'Custom': {
      'quotes': ['сохранить'],
      'history': [1, 2],
    },
  }),
);

Map<String, dynamic> session(int i) {
  final at = DateTime.utc(2026, 10, 1).add(Duration(minutes: i));
  return {
    'id': 'session-$i',
    'bookId': 'book',
    'startedAt': at.toIso8601String(),
    'endedAt': at.add(const Duration(minutes: 1)).toIso8601String(),
    'closed': true,
    'events': [
      {'kind': 'raw', 'data': 'x' * 2000},
    ],
    'ranges': [
      [0, 100],
    ],
    'spans': [
      {
        'start': at.toIso8601String(),
        'end': at.add(const Duration(minutes: 1)).toIso8601String(),
        'activeMs': 60000,
        'newChars': 100,
        'repeatChars': 10,
        'localDay': '2026-10-01',
      },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('1000 large indexes are projected once and never read by shelf queries', () async {
    final log = <String>[];
    await runZoned(
      () async {
        final db = AppDatabase(NativeDatabase.memory(logStatements: true));
        try {
          final repo = Repository(db), library = ReadingLibrary(Repository(db));
          final raw = jsonEncode({
            'title': 'Книга',
            'metadataVersion': 2,
            'cover': 'cover.png',
            'length': 500000,
            'starts': [0, 250000],
            'paragraphStarts': [
              List.generate(10000, (i) => i * 17),
              List.generate(10000, (i) => i * 17),
            ],
          });
          await db.transaction(() async {
            for (var i = 0; i < 1000; i++) {
              await repo.setMeta('reading-index:hash-$i', raw);
              await repo.setMeta(
                'reader:hash-$i',
                jsonEncode({'chapter': 1, 'textOffset': 777}),
              );
            }
          });
          log.clear();
          final clock = Stopwatch()..start();
          final result = await library.shelfIndex({
            'hash-0': {'chapter': 1, 'paragraph': 1},
          });
          await library.shelfIndex({});
          clock.stop();
          expect(result.length, 1000);
          expect(result['hash-999']!['paragraphStarts'], isNull);
          expect(log.where((s) => s.contains('FROM metadata')), isEmpty);
          final compact = jsonEncode(result).length;
          expect(compact, lessThan(raw.length * 1000 ~/ 100));
          Zone.root.print(
            '1000 indexes: ${raw.length * 1000} source bytes -> $compact shelf bytes; two shelf reads ${clock.elapsedMilliseconds} ms',
          );
          await repo.setMeta(
            'reader:hash-0',
            jsonEncode({'chapter': 1, 'paragraph': 2, 'offset': 3}),
          );
          final positions = {
            'hash-0': <String, dynamic>{
              'chapter': 1,
              'paragraph': 2,
              'offset': 3,
            },
          };
          await library.shelfIndex(positions);
          expect(positions['hash-0']!['textOffset'], 37);
          await repo.setMeta(
            'reading-index:hash-0',
            jsonEncode({
              'title': 'Обновлено',
              'length': 42,
              'starts': [0],
            }),
          );
          expect((await library.shelfInfo('hash-0'))['title'], 'Обновлено');
        } finally {
          await db.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => log.add(line),
      ),
    );
  });

  test('schema 4 upgrade keeps source catalog, indexes, events and bookmarks exact', () async {
    final dir = await Directory.systemTemp.createTemp('pepe-review-migration-');
    final file = File('${dir.path}/$currentDatabaseFilename');
    final before = <String, String>{
      'library-catalog-v1': jsonEncode({'card': card('Архив').toJson()}),
      'reading-index:hash': jsonEncode({
        'title': 'Книга',
        'cover': 'cover.png',
        'starts': [0],
        'paragraphStarts': [
          [0, 15, 80],
        ],
        'length': 100,
      }),
      'reader:hash': jsonEncode({'chapter': 0, 'paragraph': 2, 'offset': 4}),
      'reading-session:s': jsonEncode(session(1)),
      'reading-session:foreign-scalar': '42',
      'reading-session:foreign-array': '[]',
    };
    try {
      final seed = AppDatabase(NativeDatabase(file));
      for (final row in before.entries) {
        await Repository(seed).setMeta(row.key, row.value);
      }
      await seed.close();
      final old = sqlite.sqlite3.open(file.path);
      final names = [
        'reading_shelf_v1',
        'reading_statistics_sessions_v1',
        'library_catalog_revisions_v1',
      ];
      for (final row
          in old
              .select("SELECT name,sql FROM sqlite_master WHERE type='trigger'")
              .toList()) {
        if (names.any((name) => (row['sql'] as String).contains(name))) {
          old.execute('DROP TRIGGER "${row['name']}"');
        }
      }
      for (final name in names) {
        old.execute('DROP TABLE $name');
      }
      old.execute('PRAGMA user_version=4');
      old.close();
      final db = await AppDatabase.openInDirectory(dir.path);
      try {
        final repo = Repository(db), library = ReadingLibrary(Repository(db));
        for (final row in before.entries) {
          expect(await repo.meta(row.key), row.value);
        }
        final position = {
          'hash': <String, dynamic>{'chapter': 0, 'paragraph': 2, 'offset': 4},
        };
        expect(
          (await library.shelfIndex(position))['hash']!['cover'],
          'cover.png',
        );
        expect(position['hash']!['textOffset'], 84);
        final summary = (await library.statisticsSessions()).values.single;
        expect(summary.containsKey('events'), isFalse);
        expect(summary.containsKey('ranges'), isFalse);
        expect(
          (await library.value('reading-session:s'))['events'],
          session(1)['events'],
        );
        final backups = Directory('${dir.path}/backups')
            .listSync()
            .whereType<File>()
            .toList();
        expect(backups, hasLength(1));
        final copy = sqlite.sqlite3.open(backups.single.path);
        expect(copy.select('PRAGMA user_version').single.values.first, 4);
        copy.close();
      } finally {
        await db.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('catalog cache checks a small token and survives rollback and external replacement', () async {
    final log = <String>[];
    await runZoned(
      () async {
        final db = AppDatabase(NativeDatabase.memory(logStatements: true));
        try {
          final repo = Repository(db),
              catalog = LibraryRepository(
                Repository(db),
                'test',
                storageKey: personalLibraryKey,
              );
          await catalog.mutate((rows) async {
            rows['card'] = card('Исходная');
          });
          log.clear();
          for (var i = 0; i < 20; i++) {
            expect((await catalog.entries())['card']!.item.title, 'Исходная');
          }
          expect(
            log.where((s) => s.contains('SELECT value FROM metadata')),
            isEmpty,
          );
          try {
            await db.transaction(() async {
              await catalog.mutate((rows) async {
                rows['card'] = card('Откат');
              });
              throw StateError('rollback');
            });
          } on StateError {
            /* expected */
          }
          await repo.setMeta(
            personalLibraryKey,
            jsonEncode({'card': card('Внешняя').toJson()}),
          );
          final current = (await catalog.entries())['card']!;
          expect(current.item.title, 'Внешняя');
          expect(
            current.item.values['Custom'],
            card('x').item.values['Custom'],
          );
        } finally {
          await db.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => log.add(line),
      ),
    );
  });

  test('reading worker caches parsed spans and preserves totals, grouping and fractional ranges', () async {
    final worker = ReadingStatisticsWorker();
    final rows = [
      for (var i = 0; i < 1000; i++)
        {
          ...session(i),
          'sessionGroup': 'group-${i ~/ 2}',
          'spans': [
            for (var part = 0; part < 100; part++)
              {
                'start': DateTime.utc(2026, 10, 1)
                    .add(Duration(minutes: i, milliseconds: part * 600))
                    .toIso8601String(),
                'end': DateTime.utc(2026, 10, 1)
                    .add(Duration(minutes: i, milliseconds: (part + 1) * 600))
                    .toIso8601String(),
                'activeMs': 600,
                'newChars': 1,
                'repeatChars': 0,
                'localDay': '2026-10-01',
              },
          ],
        },
    ];
    try {
      final now = DateTime(2026, 10, 31);
      final all = await worker.analyze({
        'sessions': rows,
        'now': now,
        'book': null,
        'start': null,
        'end': null,
      });
      expect(all.total.milliseconds, 60000000);
      expect(all.total.sessions, 500);
      expect(all.shown.length, 500);
      expect(all.shown.every((s) => (s['spans'] as List).isEmpty), isTrue);
      final start = DateTime.utc(2026, 10, 1, 0, 0, 30),
          end = DateTime.utc(2026, 10, 1, 0, 2, 30);
      final selected = await worker.analyze({
        'now': now,
        'book': 'book',
        'start': start,
        'end': end,
      });
      final expected = readingTotals(
        rows,
        start: start,
        end: end,
        bookId: 'book',
      );
      expect(selected.total.milliseconds, expected.milliseconds);
      expect(selected.total.newChars, expected.newChars);
      expect(selected.total.repeatChars, expected.repeatChars);
      expect(selected.total.days, expected.days);
      expect(selected.total.sessions, expected.sessions);
    } finally {
      worker.dispose();
    }
  });

  testWidgets(
    'history loads bounded pages, searches old rows and keeps original events for editing',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      await tester.runAsync(() async {
        await repo.put('book', 'book', {'title': 'Ёлка', 'format': 'epub'});
        await db.transaction(() async {
          for (var i = 0; i < 350; i++) {
            await repo.setMeta(
              'reading-session:session-$i',
              jsonEncode(session(i)),
            );
          }
        });
        final history = StatisticsHistory(repo);
        final first = await history.page(
          reading: true,
          titles: {'book': 'Ёлка'},
        );
        expect(first.rows, hasLength(100));
        expect(first.hasMore, isTrue);
        expect(first.rows.first.id, 'session-349');
        final second = await history.page(
          reading: true,
          titles: {'book': 'Ёлка'},
          offset: 100,
        );
        expect(second.rows, hasLength(100));
        expect(
          first.rows
              .map((r) => r.id)
              .toSet()
              .intersection(second.rows.map((r) => r.id).toSet()),
          isEmpty,
        );
        final old = await history.page(
          reading: true,
          titles: {'book': 'Ёлка'},
          newest: false,
        );
        expect(old.rows.first.id, 'session-0');
        final search = await history.page(
          reading: true,
          titles: {'book': 'Ёлка'},
          search: 'ёЛКА автоматическая',
        );
        expect(search.rows, hasLength(100));
        expect(search.rows.first.data.containsKey('events'), isFalse);
        expect(
          (await ReadingLibrary(repo)
              .value('reading-session:session-349'))['events'],
          isNotEmpty,
        );
      });
      try {
        await tester.pumpWidget(
          MaterialApp(home: StatisticsManagementPage(repository: repo)),
        );
        final dynamic state = tester.state(
          find.byType(StatisticsManagementPage),
        );
        await ready(tester, () => !state.loading);
        expect((state.reading as List).length, 100);
        expect(state.tracks, isEmpty);
        final localDate = DateTime.utc(
          2026,
          10,
          1,
        ).toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ');
        await tester.enterText(find.byType(TextField).first, localDate);
        await tester.pump(const Duration(milliseconds: 250));
        await ready(tester, () => !state.loading);
        expect((state.reading as List).length, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(db.close);
      }
    },
  );

  test('history headers use their time indexes before loading payloads', () async {
    final log = <String>[];
    await runZoned(
      () async {
        final db = AppDatabase(NativeDatabase.memory(logStatements: true));
        try {
          final repo = Repository(db);
          await db.transaction(() async {
            for (var i = 0; i < 500; i++) {
              await repo.setMeta(
                'reading-session:session-$i',
                jsonEncode(session(i)),
              );
              await db.customStatement(
                'INSERT INTO records VALUES(?,?,1,0,?)',
                [
                  'event-$i',
                  'audio_event',
                  jsonEncode({
                    'bookId': 'book',
                    'kind': 'play',
                    'at': session(i)['startedAt'],
                  }),
                ],
              );
            }
          });
          final history = StatisticsHistory(repo);
          for (final reading in [true, false]) {
            log.clear();
            expect(
              (await history.page(reading: reading, titles: {})).rows,
              hasLength(100),
            );
            final queryStart = log.indexWhere(
              (s) => s.contains(
                reading ? "'automatic' AS source" : "'audio' AS source",
              ),
            );
            // Flutter's debug printer can wrap a long SQL statement into lines.
            final query = log.skip(queryStart).join();
            final sql = query.substring(
              query.indexOf('SELECT '),
              query.indexOf(' with args'),
            );
            final plan = await db
                .customSelect(
                  'EXPLAIN QUERY PLAN $sql',
                  variables: [Variable(101)],
                )
                .get();
            expect(
              plan.map((r) => r.read<String>('detail')).join('\n'),
              contains(
                reading ? 'reading_statistics_time_v1' : 'audio_event_time_v1',
              ),
            );
          }
        } finally {
          await db.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => log.add(line),
      ),
    );
  });

  testWidgets(
    'statistics hub queries book headers once and coalesces external changes',
    (tester) async {
      final log = <String>[];
      await runZoned(
        () async {
          final db = AppDatabase(NativeDatabase.memory(logStatements: true));
          final repo = Repository(db);
          try {
            await tester.runAsync(() async {
              await repo.put('book', 'book', {
                'title': 'Книга',
                'format': 'epub',
              });
              await repo.setMeta('reading-session:s', jsonEncode(session(0)));
            });
            log.clear();
            await tester.pumpWidget(
              MaterialApp(
                home: StatisticsHubPage(
                  repository: repo,
                  navigation: ShelfNavigation(
                    current: PepeSection.statistics,
                    onSelect: (_) {},
                    onSettings: () {},
                  ),
                ),
              ),
            );
            final dynamic state = tester.state(find.byType(StatisticsHubPage));
            await ready(tester, () => !state.loading);
            int reads() => log
                .where(
                  (s) =>
                      s.contains('SELECT id,type,revision,deleted,json_object'),
                )
                .length;
            expect(reads(), 1);
            log.clear();
            for (var i = 0; i < 20; i++) {
              repo.notifyExternalChange();
            }
            await ready(tester, () => !state.loading);
            expect(reads(), inInclusiveRange(1, 2));
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(db.close);
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => log.add(line),
        ),
      );
    },
  );

  test(
    'missing artwork is cached and a folder rescan discovers a new cover',
    () async {
      final dir = await Directory.systemTemp.createTemp('pepe-missing-cover-');
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final file = File('${dir.path}/track.mp3');
        await file.writeAsBytes([1, 2, 3]);
        final repo = Repository(db),
            assets = AssetStore(Repository(db), Directory('${dir.path}/cache'));
        final track = await assets.connectAudioFolder(
          [XFile(file.path)],
          root: dir.path,
          title: 'Book',
        );
        final store = ArtworkStore(assets);
        expect(await store.load(track.bookId), isNull);
        expect(
          await repo.meta('audio-cover-missing:${track.bookId}'),
          isNotNull,
        );
        expect(await store.load(track.bookId), isNull);
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const ui.Color(0xff118855), ui.BlendMode.src);
        final picture = recorder.endRecording(),
            image = await recorderImage(picture);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await File('${dir.path}/cover.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        await assets.connectAudioFolder(
          [XFile(file.path)],
          root: dir.path,
          title: 'Book',
          replaceBookId: track.bookId,
        );
        expect(await store.load(track.bookId), isNotNull);
        expect(await repo.meta('audio-cover-missing:${track.bookId}'), isNull);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

Future<ui.Image> recorderImage(ui.Picture picture) => picture.toImage(4, 4);
