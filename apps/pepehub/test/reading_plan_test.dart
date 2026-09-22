import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_plan.dart';
import 'package:pepehub/ui/reading_plan_page.dart';
import 'package:pepehub/ui/app_theme.dart';

Map<String, dynamic> sample({String book = 'b', String hash = 'h'}) => {
  'bookId': book,
  'hash': hash,
  'speedVersion': 1,
  'speedActiveMs': 360000,
  'speedChars': 600,
  'speedMoves': 4,
  'spans': [],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('speed pairs only uninterrupted active text; skips, idle and paused partial pages excluded', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    var now = DateTime(2026, 9, 20, 12);
    final a = ReadingActivity(
      repo,
      bookId: 'b',
      hash: 'h',
      length: 20000,
      clock: () => now,
    );
    await a.start(0, runTimer: false);
    now = now.add(const Duration(seconds: 30));
    a.move(1000);
    now = now.add(const Duration(seconds: 10));
    a.move(9000, jump: true);
    now = now.add(const Duration(seconds: 30));
    a.move(9500);
    expect(a.snapshot()['speedChars'], 1500);
    expect(a.snapshot()['speedActiveMs'], 60000);
    await a.pause('search');
    now = now.add(const Duration(hours: 2));
    a.resume();
    now = now.add(const Duration(seconds: 30));
    a.move(9600); // partial page
    expect(a.snapshot()['speedChars'], 1500);
    now = now.add(const Duration(seconds: 30));
    a.move(9700);
    expect(a.snapshot()['speedActiveMs'], 90000);
    now = now.add(const Duration(minutes: 3));
    a.tick();
    a.move(9800);
    expect(a.snapshot()['speedChars'], 1600);
    a.move(0, jump: true);
    now = now.add(const Duration(minutes: 1));
    a.move(1000);
    expect(a.repeated, 1000);
    expect(a.snapshot()['speedChars'], 2600);
    expect(a.snapshot()['speedActiveMs'], 150000);
    final before = a.speedChars;
    now = now.add(const Duration(milliseconds: 500));
    a.move(2000);
    expect(a.speedChars, before); // rapid page flip
    await a.close();
    final saved = await ReadingLibrary(repo).value('reading-session:${a.id}');
    expect(saved['speedMoves'], 4);
    expect(saved['events'], hasLength(8)); // no per-page speed events
  });
  test('forecast uses uncovered target text, scopes version, ignores cursor and legacy totals', () {
    final now = DateTime(2026, 9, 20, 12);
    final f = forecastReading(
      plan: ReadingPlan(
        targetPercent: 50,
        dailyMinutes: 20,
        deadline: DateTime(2026, 9, 26),
      ),
      bookId: 'b',
      hash: 'h',
      length: 10000,
      coverage: [
        [0, 1000],
        [500, 1500],
        [8000, 9000],
      ],
      sessions: [
        sample(),
        sample(hash: 'old'),
        sample(book: 'other'),
        {
          'bookId': 'b',
          'hash': 'h',
          'newChars': 999999,
          'position': 10000,
          'spans': [],
        },
      ],
      now: now,
    );
    expect(f.coveredChars, 1500);
    expect(f.remainingChars, 3500);
    expect(f.charsPerMinute, 100);
    expect(f.remainingMinutes, 35);
    expect(f.minutesPerDay, 5);
    expect(f.expectedDate, DateTime(2026, 9, 21));
    expect(f.overdue, isFalse);
  });
  test('today budget, deadlines, sparse data, PDF and completed goal have explicit outcomes', () {
    final now = DateTime(2026, 9, 20, 12);
    ReadingForecast forecast({
      List<Map<String, dynamic>>? sessions,
      List<List<int>> coverage = const [],
      int length = 4000,
      DateTime? deadline,
    }) => forecastReading(
      plan: ReadingPlan(dailyMinutes: 20, deadline: deadline),
      bookId: 'b',
      hash: 'h',
      length: length,
      coverage: coverage,
      sessions: sessions ?? [sample()],
      now: now,
    );
    final active = {
      ...sample(),
      'spans': [
        {
          'start': DateTime(2026, 9, 20, 10).toIso8601String(),
          'end': DateTime(2026, 9, 20, 10, 10).toIso8601String(),
        },
      ],
    };
    final f = forecast(sessions: [active], deadline: DateTime(2026, 9, 20));
    expect(f.todayMs, 600000);
    expect(f.expectedDate, DateTime(2026, 9, 22));
    expect(f.minutesPerDay, 40);
    expect(f.overdue, isFalse);
    expect(forecast(deadline: DateTime(2026, 9, 19)).overdue, isTrue);
    expect(forecast(sessions: []).remainingMinutes, isNull);
    expect(
      forecast(
        sessions: [
          {...sample(), 'speedActiveMs': 59000},
        ],
      ).remainingMinutes,
      isNull,
    );
    expect(forecast(length: 0).remainingMinutes, isNull);
    final late = forecastReading(
      plan: const ReadingPlan(dailyMinutes: 20),
      bookId: 'b',
      hash: 'h',
      length: 1000,
      coverage: [],
      sessions: [sample()],
      now: DateTime(2026, 9, 20, 23, 59),
    );
    expect(late.expectedDate, DateTime(2026, 9, 21));
    final done = forecast(
      coverage: [
        [0, 4000],
      ],
      sessions: [],
      deadline: DateTime(2026, 9, 19),
    );
    expect(done.complete, isTrue);
    expect(done.remainingMinutes, 0);
    expect(done.overdue, isFalse);
    final manual = {...active, 'source': 'manual'};
    expect(forecast(sessions: [manual]).todayMs, 0);
    expect(forecast(sessions: [manual]).charsPerMinute, isNull);
  });
  testWidgets(
    'book plan validates, persists deadline, survives metadata edits and supports delete/undo',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory temp;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('reading-plan-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        final file = File('${temp.path}/Остров.txt');
        await file.writeAsString('Море и остров. ' * 500);
        final assets = AssetStore(repo, Directory('${temp.path}/assets'));
        asset = await assets.importBook(XFile(file.path));
        await ReadingLibrary(repo).index(assets, asset);
        await repo.setMeta(
          'reading-session:speed',
          jsonEncode(sample(book: asset.bookId, hash: asset.hash)),
        );
        await repo.setMeta(
          'reading-coverage:${asset.hash}',
          jsonEncode({
            'ranges': [
              [0, 1000],
            ],
          }),
        );
        final font = File('C:/Windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          await (FontLoader(
            'Roboto',
          )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
        }
        final icons = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icons.exists()) {
          await (FontLoader(
            'MaterialIcons',
          )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
        }
      });
      Future<void> settle() async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> scrollTo(Finder finder) async {
        for (
          var i = 0;
          i < 12 && finder.hitTestable().evaluate().isEmpty;
          i++
        ) {
          await tester.drag(find.byType(ListView).first, const Offset(0, -200));
          await tester.pumpAndSettle();
        }
      }

      try {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: RepaintBoundary(
              key: key,
              child: ReadingPlanPage(repository: repo, bookId: asset.bookId),
            ),
          ),
        );
        await settle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Минут в день'),
          '0',
        );
        await tester.tap(find.text('Сохранить план'));
        await settle();
        expect(find.text('Укажите от 1 до 1440 минут в день.'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextField, 'Минут в день'),
          '25',
        );
        await tester.tap(find.text('Срок завершения'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить план'));
        await settle();
        var stored = (await tester.runAsync(
          () => ReadingPlans(repo).load(asset.bookId),
        ))!;
        expect(stored.saved!.dailyMinutes, 25);
        expect(stored.saved!.deadline, isNotNull);
        await tester.runAsync(
          () =>
              ReadingLibrary(repo)
                  .saveDetails(asset.bookId, {'title': 'Остров и море'}),
        );
        await tester.tap(find.byTooltip('Обновить прогноз'));
        await settle();
        expect(find.text('Остров и море'), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('build/reading-plan-preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
        await scrollTo(find.text('Удалить план'));
        await tester.tap(find.text('Удалить план'));
        await settle();
        expect(
          (await tester.runAsync(() => ReadingPlans(repo).load(asset.bookId)))!
              .saved,
          isNull,
        );
        await tester.tap(find.text('Отменить'));
        await settle();
        stored = (await tester.runAsync(
          () => ReadingPlans(repo).load(asset.bookId),
        ))!;
        expect(stored.saved!.dailyMinutes, 25);
        expect(stored.coverage, [
          [0, 1000],
        ]);
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.pumpWidget(
          MaterialApp(
            home: ReadingPlanPage(repository: repo, bookId: asset.bookId),
          ),
        );
        await settle();
        expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'Минут в день'))
              .controller!
              .text,
          '25',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.runAsync(() async {
          await db.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );
}
