import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pepehub/ui/reading_statistics_page.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';
import 'package:pepehub/ui/goal_settings_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/storage_usage.dart';
import 'package:pepehub/ui/app_preferences.dart';
import 'package:pepehub/ui/goal_reminders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reading in [true, false]) {
    testWidgets(
      'statistics opens the common goal editor and refreshes after return: reading=$reading',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await db.close();
        });
        await repo.setMeta('reading-daily-goal', '30');
        await repo.setMeta(
          'audio-listening-goals',
          '{"dailyMinutes":10,"weeklyMinutes":30}',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: reading
                ? ReadingStatisticsPage(repository: repo)
                : AudioStatisticsPage(repository: repo),
          ),
        );
        final dynamic stats = tester.state(
          find.byType(reading ? ReadingStatisticsPage : AudioStatisticsPage),
        );
        await ready(tester, () => reading ? !stats.loading : !stats.busy);
        expect(stats.error, isNull);
        await tester.scrollUntilVisible(
          find.byTooltip('Настроить цели'),
          350,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Настроить цели'));
        await tester.pumpAndSettle();
        expect(find.byType(GoalSettingsPage), findsOneWidget);
        await tester.tap(
          find.byTooltip(
            reading
                ? 'Увеличить: Чтение в день'
                : 'Увеличить: Прослушивание в день',
          ),
        );
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        if (reading) {
          final dynamic state = tester.state(
            find.byType(ReadingStatisticsPage),
          );
          expect(state.goal, 35);
        } else {
          final dynamic state = tester.state(find.byType(AudioStatisticsPage));
          expect(state.goals.dailyMinutes, 15);
        }
        expect(await repo.records('book'), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  test('startup choice overrides last section without changing it', () async {
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    addTearDown(db.close);
    await repo.setMeta('library-section', 'audio');
    expect(await startupSection(repo), 'audio');
    await repo.setMeta('startup-section', 'metadata');
    expect(await startupSection(repo), 'metadata');
    expect(await repo.meta('library-section'), 'audio');
    await repo.setMeta('startup-section', 'last');
    expect(await startupSection(repo), 'audio');
    await repo.setMeta('startup-section', 'unknown old value');
    expect(await startupSection(repo), 'audio');
  });

  test('reminders respect opt-in, local time, foreground and persisted daily deduplication', () async {
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    addTearDown(db.close);
    var now = DateTime(2026, 11, 5, 19, 59), foreground = true, shown = 0;
    GoalReminderService service() => GoalReminderService(
      repo,
      foreground: () => foreground,
      show: () {
        shown++;
        return true;
      },
      now: () => now,
    );
    final first = service();
    addTearDown(first.dispose);
    await first.check();
    expect(shown, 0);
    await const GoalReminderPreferences(enabled: true).save(repo);
    await first.check();
    expect(shown, 0);
    now = DateTime(2026, 11, 5, 20);
    foreground = false;
    await first.check();
    expect(shown, 0);
    foreground = true;
    await first.check();
    await first.check();
    expect(shown, 1);
    first.dispose();
    final restarted = service();
    addTearDown(restarted.dispose);
    await restarted.check();
    expect(shown, 1);
    now = DateTime(2026, 11, 6, 21);
    await restarted.check();
    expect(shown, 2);
    await repo.setMeta('goal-reminder', '{broken');
    expect((await GoalReminderPreferences.load(repo)).enabled, false);
  });

  test('cache cleanup preserves originals, covers, partial writes and unexpected files', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-storage-');
    addTearDown(() => root.delete(recursive: true));
    final cache = await Directory(p.join(root.path, 'reading-cache')).create();
    final covers = await Directory(p.join(root.path, 'reading-covers'))
        .create();
    final hash = 'a' * 64;
    final temporary = await File(p.join(cache.path, '$hash.pdf'))
        .writeAsString('temporary');
    final partial = await File(p.join(cache.path, '$hash.pdf.partial'))
        .writeAsString('pending');
    final original = await File(p.join(root.path, '$hash.pdf'))
        .writeAsString('original');
    final cover = await File(p.join(covers.path, '$hash.png'))
        .writeAsString('cover');
    final unknown = await File(p.join(cache.path, 'my-book.pdf'))
        .writeAsString('keep');
    final nested = await Directory(p.join(cache.path, 'nested')).create();
    final nestedFile = await File(p.join(nested.path, '$hash.pdf'))
        .writeAsString('keep');
    final usage = StorageUsage(root);
    final before = await usage.measure();
    expect(before.covers, 5);
    expect(await usage.clearTemporaryCopies(), 9);
    expect(await temporary.exists(), false);
    for (final file in [partial, original, cover, unknown, nestedFile]) {
      expect(await file.exists(), true);
    }
    expect((await usage.measure()).total, before.total - 9);
    expect(await usage.clearTemporaryCopies(), 0);
  });
}
