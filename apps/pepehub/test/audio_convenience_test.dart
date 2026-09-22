import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/statistics_export.dart';
import 'package:pepehub/audio/listening_analytics.dart';

void main() {
  test(
    'edit and undo preserve bookmark identity, position and revision',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final journal = AudioJournal(repo);
      try {
        await journal.bookmark('b', 't', 12345, 'Before');
        final original = (await journal.list('audio_bookmark')).single;
        await journal.editBookmark(original.id, 'After');
        await journal.deleteBookmark(original.id);
        expect(await journal.list('audio_bookmark'), isEmpty);
        await journal.restoreBookmark(original.id);
        final restored = (await journal.list('audio_bookmark')).single;
        expect(restored.id, original.id);
        expect(restored.payload!['title'], 'After');
        expect(restored.payload!['positionMs'], 12345);
        expect(restored.revision, greaterThan(original.revision));
        await const ListeningGoals(
          dailyMinutes: 40,
          weeklyMinutes: 200,
        ).save(repo);
        expect((await ListeningGoals.load(repo)).dailyMinutes, 40);
        expect(
          () => const ListeningGoals(dailyMinutes: -1).save(repo),
          throwsArgumentError,
        );
      } finally {
        await db.close();
      }
    },
  );
  test(
    'CSV escapes user text and JSON exports selected metrics and sessions',
    () {
      final analysis = analyzeListening({
        'events': [
          {
            'kind': 'listen',
            'bookId': 'b',
            'trackId': 't',
            'positionMs': 0,
            'endMs': 2000,
            'wallMs': 1000,
            'speed': 2.0,
            'at': '2026-09-16T10:00:00Z',
            'localDay': '2026-09-16',
          },
        ],
        'book': null,
        'cutoff': null,
      });
      final csv = statisticsCsv(analysis, {'b': '=SUM(1,2) "Title"'});
      expect(csv, contains("'=SUM(1,2)"));
      expect(csv, contains('""Title""'));
      final data = jsonDecode(
        statisticsJson(analysis, {'b': 'Title'}, period: 7),
      );
      expect(data['activeMs'], 1000);
      expect(data['sessions'], hasLength(1));
      expect(data['materialMs'], 2000);
    },
  );
}
