import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_statistics_history.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/ui/statistics_hub_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

LibraryEntry card(
  String id, {
  String? source,
  Map<String, dynamic> values = const {},
}) => LibraryEntry(
  personalLibraryItem(id, 'audiobook', {
    'title': 'Аудио $id',
    'status': 'finished',
    'progress': 120,
    'unit': 'minutes',
    'endDate': '${DateTime.now().year}-01-10',
    ...values,
  }),
  sourceBookId: source,
);

void main() {
  test(
    'manual metadata counts minutes and hours and subtracts native media at 2x',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final client = MockClient((_) => throw StateError('No network'));
      final library = LibraryService(repo, client);
      addTearDown(() async {
        library.dispose();
        client.close();
        await db.close();
      });
      await library.repository.mutate((entries) async {
        entries['minutes'] = card('minutes');
        entries['hours'] = card(
          'hours',
          source: 'native',
          values: {'progress': 1.5, 'unit': 'hours'},
        );
        entries['planned'] = card('planned', values: {'status': 'planned'});
        entries['active'] = card('active', values: {'status': 'active'});
        entries['trash'] = card(
          'trash',
          values: {'pepehub_deleted_at': '2026-01-01'},
        );
        entries['unknown-date'] = card(
          'unknown-date',
          values: {'endDate': null},
        );
        entries['percent'] = card('percent', values: {'unit': 'percent'});
        entries['automatic'] = card('automatic', source: 'auto');
      });
      await repo.setMeta(
        'obsidian-auto:personal:automatic',
        jsonEncode({'progress': 120}),
      );
      final event = {
        'kind': 'listen',
        'bookId': 'native',
        'trackId': 'track',
        'positionMs': 0,
        'endMs': 3600000,
        'mediaMs': 3600000,
        'wallMs': 1800000,
        'speed': 2,
        'at': '${DateTime.now().year}-01-10T12:00:00Z',
        'localDay': '${DateTime.now().year}-01-10',
        'offsetMinutes': 0,
      };
      await AudioJournal(repo).put('audio_event', 'listen', event);
      final before = await repo.record('listen');
      final history = await AudioStatisticsHistory.load(repo);
      expect(AudioStats(history.events).books, {
        'card:minutes': 7200000,
        'native': 1800000,
      });
      expect(AudioStats([...history.events, event]).books['native'], 3600000);
      expect(history.events.every((e) => e['timeKnown'] == false), isTrue);
      expect((await repo.record('listen'))!.payload, before!.payload);
      expect(await repo.records('audio_event'), hasLength(1));
    },
  );

  testWidgets('saved metadata appears in hub and detailed audio statistics', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    final library = LibraryService(repo, client);
    await tester.runAsync(() async {
      await library.repository.mutate((entries) async {
        entries['manual'] = card('manual');
      });
      final entry = (await library.repository.entries())['manual']!;
      await library.save('manual', {
        ...entry.item.values,
        'progress': 150,
      }, original: entry.item.values);
    });
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: StatisticsHubPage(
            repository: repo,
            library: library,
            navigation: ShelfNavigation(
              current: PepeSection.statistics,
              onSelect: (_) {},
              onSettings: () {},
            ),
          ),
        ),
      );
      final dynamic hub = tester.state(find.byType(StatisticsHubPage));
      await ready(tester, () => !hub.loading);
      expect(hub.error, isNull);
      expect((hub.audioDays as Map).values.single, 9000000);
      expect(
        hub.calendar.days['${DateTime.now().year}-01-10']['card:manual'],
        9000000,
      );
      await tester.runAsync(() async {
        final entry = (await library.repository.entries())['manual']!;
        await library.save('manual', {
          ...entry.item.values,
          'progress': 180,
        }, original: entry.item.values);
      });
      await ready(tester, () => !hub.loading);
      expect((hub.audioDays as Map).values.single, 10800000);
      await tester.pumpWidget(
        MaterialApp(
          home: AudioStatisticsPage(
            repository: repo,
            initialBookId: 'card:manual',
          ),
        ),
      );
      final dynamic audio = tester.state(find.byType(AudioStatisticsPage));
      audio.period = 0;
      await ready(tester, () => audio.stats != null && !audio.busy);
      expect(audio.error, isNull);
      expect(audio.stats.wallMs, 10800000);
      expect(audio.titles['card:manual'], 'Аудио manual');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        library.dispose();
        client.close();
        await db.close();
      });
    }
  });

  test('1000 books and 1000 audiobooks use compact aggregates without loading tracks or text indexes', () async {
    final log = <String>[];
    await runZoned(
      () async {
        final db = AppDatabase(NativeDatabase.memory(logStatements: true));
        final repo = Repository(db);
        final client = MockClient((_) => throw StateError('No network'));
        final library = LibraryService(repo, client);
        try {
          await library.repository.mutate((entries) async {
            for (var i = 0; i < 1000; i++) {
              entries['audio-$i'] = card('audio-$i');
              entries['book-$i'] = LibraryEntry(
                personalLibraryItem('book-$i', 'book', {
                  'title': 'Книга $i',
                  'status': 'finished',
                  'progress': 300,
                  'unit': 'pages',
                }),
              );
            }
          });
          log.clear();
          final history = await AudioStatisticsHistory.load(repo);
          expect(history.events, hasLength(1000));
          expect(AudioStats(history.events).wallMs, 1000 * 7200000);
          expect(
            log.where(
              (s) =>
                  s.contains('audio_tracks') ||
                  s.contains('reading-index:') ||
                  s.contains('SELECT id,payload'),
            ),
            isEmpty,
          );
        } finally {
          library.dispose();
          client.close();
          await db.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, parent, zone, line) => log.add(line),
      ),
    );
  });
}
