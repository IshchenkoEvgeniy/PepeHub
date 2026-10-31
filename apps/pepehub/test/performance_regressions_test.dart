import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';
import 'package:pepehub/ui/audio_page.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'audio_resume_controller_test.dart' show Harness;
import 'video_player_tools_widget_test.dart' show ready;

Map<String, dynamic> listen(int ms) {
  final now = DateTime.now();
  return {
    'kind': 'listen',
    'bookId': 'book',
    'trackId': 'track',
    'positionMs': 0,
    'endMs': ms,
    'wallMs': ms,
    'speed': 1.0,
    'at': now.toUtc().toIso8601String(),
    'localDay': dayKey(now),
    'offsetMinutes': now.timeZoneOffset.inMinutes,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [390.0, 1280.0]) {
    testWidgets('300 audio chapters stay lazy at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = Harness();
      await tester.runAsync(() async {
        await h.open();
        await h.controller.shutdown();
        await h.db.transaction(() async {
          for (var i = 2; i < 300; i++) {
            final name = 'chapter-${i.toString().padLeft(3, '0')}.mp3';
            final path = '${h.root.path}/0.mp3';
            await h.db.customStatement(
              'INSERT INTO local_assets VALUES(?,?,?,?,?,?)',
              ['track$i', 'book', name, path, 'hash$i', 4],
            );
            await h.db.customStatement(
              'INSERT INTO audio_resources VALUES(?,?,?)',
              ['hash$i', path, 4],
            );
            await h.db.customStatement(
              'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
              ['track$i', 'edition', 'hash$i', i, name, 100000],
            );
          }
        });
        await h.restart();
      });
      try {
        await tester.pumpWidget(
          MaterialApp(home: AudioPage(controller: h.controller)),
        );
        await tester.pumpAndSettle();
        if (width >= 860) {
          var panelReady = false;
          final dynamic state = tester.state(find.byType(AudioPage));
          (state.seekRows as Future).then((_) => panelReady = true);
          await ready(tester, () => panelReady);
        }
        if (width < 860) {
          await tester.scrollUntilVisible(
            find.text('Главы (300)'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Главы (300)'));
          await tester.pumpAndSettle();
        }
        expect(
          find.byType(ListTile).evaluate().length,
          inInclusiveRange(1, 35),
        );
        final chapters = find
            .byWidgetPredicate(
              (w) =>
                  w is ListView &&
                  w.childrenDelegate is SliverChildBuilderDelegate,
            )
            .last;
        final scrollable = find
            .descendant(of: chapters, matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(
          find.text('chapter-299.mp3'),
          2000,
          maxScrolls: 20,
          scrollable: scrollable,
        );
        expect(find.text('chapter-299.mp3'), findsOneWidget);
        expect(find.byType(ListTile).evaluate().length, lessThan(35));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        final closing = h.close().then((_) => closed = true);
        await ready(tester, () => closed);
        await closing;
      }
    });
  }

  test(
    'position ticks update progress without notifying the whole player',
    () async {
      final h = Harness();
      await h.open();
      try {
        var pageUpdates = 0, progressUpdates = 0;
        h.controller.addListener(() => pageUpdates++);
        h.controller.playbackPosition.addListener(() => progressUpdates++);
        for (var i = 1; i <= 100; i++) {
          h.player.position = Duration(milliseconds: 3000 + i * 100);
          h.player.positions.add(h.player.position);
        }
        expect(pageUpdates, 0);
        expect(progressUpdates, 100);
        expect(
          h.controller.playbackPosition.value,
          const Duration(seconds: 13),
        );
        await h.controller.skipToQueueItem(0);
        expect(pageUpdates, greaterThan(0));
      } finally {
        await h.close();
      }
    },
  );

  test(
    'file database uses WAL and a snapshot includes committed WAL pages',
    () async {
      final root = await Directory.systemTemp.createTemp('pepe-performance-');
      final db = await AppDatabase.openInDirectory(root.path);
      try {
        expect(
          (await db.customSelect('PRAGMA journal_mode').getSingle())
              .read<String>('journal_mode'),
          'wal',
        );
        expect(
          (await db.customSelect('PRAGMA synchronous').getSingle()).read<int>(
            'synchronous',
          ),
          2,
        );
        await db.customStatement('PRAGMA wal_autocheckpoint=0');
        await Repository(db).put('book', 'recent', {'title': 'Latest commit'});
        final snapshot = '${root.path}/snapshot.sqlite';
        await db.customStatement('VACUUM INTO ?', [snapshot]);
        final copy = sqlite.sqlite3.open(snapshot);
        try {
          expect(
            copy
                .select("SELECT id FROM records WHERE id='recent'")
                .single['id'],
            'recent',
          );
        } finally {
          copy.close();
        }
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'journal query uses the book index and ignores damaged payloads',
    () async {
      final log = <String>[];
      await runZoned(
        () async {
          final db = AppDatabase(NativeDatabase.memory(logStatements: true));
          try {
            final repo = Repository(db);
            await db.transaction(() async {
              for (var i = 0; i < 3000; i++) {
                await db.customStatement(
                  'INSERT INTO records VALUES(?,?,1,0,?)',
                  [
                    'event-$i',
                    'audio_event',
                    jsonEncode({...listen(1000), 'bookId': 'book-${i % 100}'}),
                  ],
                );
              }
              await db.customStatement(
                "INSERT INTO records VALUES('damaged','audio_event',1,0,'{broken')",
              );
            });
            log.clear();
            final rows = await AudioJournal(repo)
                .list('audio_event', bookId: 'book-42', limit: 5);
            expect(rows, hasLength(5));
            expect(
              rows.every((r) => r.payload!['bookId'] == 'book-42'),
              isTrue,
            );
            final query = log.singleWhere(
              (s) => s.startsWith('Drift: Sent SELECT * FROM records'),
            );
            final sql = query.substring(
              'Drift: Sent '.length,
              query.indexOf(' with args'),
            );
            final plan = await db
                .customSelect(
                  'EXPLAIN QUERY PLAN $sql',
                  variables: [Variable('book-42'), Variable(5)],
                )
                .get();
            final details = plan
                .map((r) => r.read<String>('detail'))
                .join('\n');
            expect(details, contains('records_audio_day_v2'));
            log.clear();
            await repo.records('session');
            expect(log.join(), isNot(contains('ORDER BY')));
            log.clear();
            await repo.put('book', 'local', {'title': 'Local'});
            expect(
              log.join(),
              isNot(contains('INSERT OR IGNORE INTO legacy_cloud_outbox')),
            );
            expect(log.join(), isNot(contains('DELETE FROM outbox')));
          } finally {
            await db.close();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            log.add(line);
          },
        ),
      );
    },
  );

  testWidgets(
    'statistics stays idle, reacts to journal writes and reuses history when changing range',
    (tester) async {
      final log = <String>[];
      await runZoned(
        () async {
          final db = AppDatabase(NativeDatabase.memory(logStatements: true));
          final repo = Repository(db);
          try {
            await tester.runAsync(() async {
              await repo.put('book', 'book', {
                'title': 'Book',
                'format': 'audio',
              });
              await AudioJournal(repo)
                  .put('audio_event', 'listen', listen(60000));
              final old = DateTime.now().subtract(const Duration(days: 365));
              final historical = {
                ...listen(1000),
                'bookId': 'historical',
                'at': old.toUtc().toIso8601String(),
                'localDay': dayKey(old),
              };
              await db.transaction(() async {
                for (var i = 0; i < 12000; i++) {
                  await db.customStatement(
                    'INSERT INTO records VALUES(?,?,1,0,?)',
                    [
                      'old-$i',
                      'audio_event',
                      jsonEncode({
                        ...historical,
                        'positionMs': i * 1000,
                        'endMs': (i + 1) * 1000,
                      }),
                    ],
                  );
                }
              });
            });
            int reads() => log
                .where(
                  (s) =>
                      s.contains(
                        "SELECT id,payload FROM records WHERE type='audio_event'",
                      ) ||
                      s.contains(
                        'SELECT id,CASE WHEN deleted=0 AND json_valid(payload)',
                      ),
                )
                .length;
            await tester.pumpWidget(
              MaterialApp(home: AudioStatisticsPage(repository: repo)),
            );
            await ready(
              tester,
              () => find.text('Пройдено материала').evaluate().isNotEmpty,
            );
            final initialReads = reads();
            expect(initialReads, 1);
            final dynamic state = tester.state(
              find.byType(AudioStatisticsPage),
            );
            expect(state.stats.wallMs, 60000);
            expect(state.analytics.lifetime.wallMs, 12060000);
            await tester.pump(const Duration(seconds: 46));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump();
            expect(
              reads(),
              initialReads,
              reason: 'No unchanged history polling',
            );
            await tester.runAsync(
              () => db.transaction(
                () =>
                    AudioJournal(Repository(db))
                        .put('audio_event', 'listen', listen(120000)),
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
            await ready(
              tester,
              () => !state.busy && state.stats.wallMs == 120000,
            );
            expect(state.analytics.lifetime.wallMs, 12120000);
            expect(reads(), initialReads + 1);
            await tester.tap(find.text('7 дней'));
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 150)),
            );
            await tester.pump();
            expect(
              reads(),
              initialReads + 1,
              reason: 'Changing range reuses the snapshot',
            );
            await tester.runAsync(
              () => AudioJournal(repo).deleteEvent('listen'),
            );
            await tester.pump(const Duration(milliseconds: 350));
            await ready(
              tester,
              () =>
                  reads() == initialReads + 2 &&
                  !state.busy &&
                  state.stats.wallMs == 0,
            );
            expect(state.analytics.lifetime.wallMs, 12000000);
            expect(reads(), initialReads + 2);
            expect(
              log
                  .where(
                    (s) => s.contains(
                      "SELECT id,payload FROM records WHERE type='audio_event'",
                    ),
                  )
                  .length,
              1,
            );
            await tester.runAsync(() async {
              await db.customStatement(
                'INSERT INTO records VALUES(?,?,1,0,?)',
                ['external', 'audio_event', jsonEncode(listen(60000))],
              );
              repo.notifyExternalChange();
            });
            await tester.pump(const Duration(milliseconds: 350));
            await ready(
              tester,
              () =>
                  reads() == initialReads + 3 &&
                  !state.busy &&
                  state.stats.wallMs == 60000,
            );
            await tester.runAsync(() async {
              try {
                await db.transaction(() async {
                  await AudioJournal(repo)
                      .put('audio_event', 'external', listen(180000));
                  throw StateError('rollback');
                });
              } on StateError catch (error) {
                expect(error.message, 'rollback');
              }
            });
            await tester.pump(const Duration(milliseconds: 350));
            await ready(
              tester,
              () => reads() == initialReads + 4 && !state.busy,
            );
            expect(state.stats.wallMs, 60000);
            expect(state.error, isNull);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.runAsync(db.close);
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            log.add(line);
          },
        ),
      );
    },
  );
}
