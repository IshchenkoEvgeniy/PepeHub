import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';

import 'performance_regressions_test.dart' show listen;
import 'video_player_tools_widget_test.dart' show ready;

void main() {
  testWidgets(
    'a chosen audiobook gets its own panel; details live under info',
    (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      await tester.runAsync(() async {
        await repo.put('book', 'book', {'title': 'Book', 'format': 'audio'});
        await AudioJournal(repo).put('audio_event', 'listen', listen(60000));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AudioStatisticsPage(repository: repo, initialBookId: 'book'),
        ),
      );
      await ready(
        tester,
        () => find.text('Текущая серия').evaluate().isNotEmpty,
      );
      final panel = find.byKey(const ValueKey('audio-book-panel'));
      expect(panel, findsOneWidget);
      // The panel leads the page, above the goals.
      expect(
        tester.getTopLeft(panel).dy,
        lessThan(tester.getTopLeft(find.text('Текущая серия')).dy),
      );
      // Without a known duration there is no fake progress.
      expect(find.text('Длительность неизвестна'), findsOneWidget);
      expect(find.textContaining('без пауз и перемоток'), findsNothing);
      await tester.tap(find.byTooltip('О статистике'));
      await tester.pumpAndSettle();
      expect(find.textContaining('без пауз и перемоток'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    },
  );
}
