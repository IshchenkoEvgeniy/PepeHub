import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_log.dart';
import 'package:pepehub/ui/reading_statistics_page.dart';
import 'package:pepehub/ui/reading_book_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('idle, panels and background excluded; jumps excluded; rereads persist across sessions', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), lib = ReadingLibrary(Repository(db));
    var now = DateTime(2026, 9, 19, 12);
    final errors = <Object>[];
    final a = ReadingActivity(
      repo,
      bookId: 'b',
      hash: 'h',
      length: 1000,
      clock: () => now,
      onError: errors.add,
    );
    await a.start(0, runTimer: false);
    now = now.add(const Duration(seconds: 10));
    a.move(200);
    now = now.add(const Duration(seconds: 10));
    a.move(400);
    await a.pause('panel');
    now = now.add(const Duration(minutes: 20));
    a.resume();
    a.move(0, jump: true);
    now = now.add(const Duration(seconds: 10));
    a.move(200);
    now = now.add(const Duration(minutes: 5));
    a.tick();
    expect(a.fresh, 400);
    expect(a.repeated, 200);
    expect(readingTotals([a.snapshot()]).milliseconds, 150000);
    a.move(1000, jump: true);
    await a.close();
    expect((await lib.value('reading-dates:b'))['finishedAt'], isNull);
    final b = ReadingActivity(
      repo,
      bookId: 'b',
      hash: 'h',
      length: 1000,
      clock: () => now,
      onError: errors.add,
    );
    await b.start(100, runTimer: false);
    now = now.add(const Duration(seconds: 10));
    b.move(500);
    expect(b.fresh, 100);
    expect(b.repeated, 300);
    now = now.add(const Duration(seconds: 10));
    b.move(1000, chapterEnded: true);
    await b.close();
    expect((await lib.value('reading-dates:b'))['finishedAt'], isNotNull);
    expect((await lib.value('reading-coverage:h'))['ranges'], [
      [0, 1000],
    ]);
    expect(errors, isEmpty);
  });
  test('three hours create compact events and one day log with one backup', () async {
    final dir = await Directory.systemTemp.createTemp('reading-log-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), lib = ReadingLibrary(Repository(db));
      await lib.update('reading-library-root:test', {
        'path': dir.path,
        'bookIds': ['b'],
        'title': 'Books',
      });
      var now = DateTime(2026, 9, 19, 8);
      final errors = <Object>[];
      final a = ReadingActivity(
        repo,
        bookId: 'b',
        hash: 'h',
        length: 100000,
        clock: () => now,
        export: ReadingLog(repo).export,
        onError: errors.add,
      );
      await a.start(0, runTimer: false);
      for (var i = 0; i < 180; i++) {
        now = now.add(const Duration(minutes: 1));
        a.touch();
        await a.checkpoint();
      }
      await a.pause('background');
      await a.close();
      final saved = (await lib.entries('reading-session:')).values.single;
      expect(readingTotals([saved]).milliseconds, 10800000);
      expect(saved['events'], hasLength(3));
      expect(saved['spans'], hasLength(1));
      final files = await Directory(
        '${dir.path}/.pepehub/reading/logs/2026-09-19',
      ).list().toList();
      expect(files.length, 2);
      final packet = jsonDecode(
        await File(
          '${dir.path}/.pepehub/reading/logs/2026-09-19/reading-2026-09-19.json',
        ).readAsString(),
      );
      expect(packet['sessions'], hasLength(1));
      expect(packet['sessions'][0]['closed'], true);
      expect(errors, isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'calendar splits midnight and custom range excludes inactive gap',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      var now = DateTime(2026, 9, 19, 23, 59, 30);
      final a = ReadingActivity(
        Repository(db),
        bookId: 'b',
        hash: 'h',
        length: 100,
        clock: () => now,
      );
      await a.start(0, runTimer: false);
      now = now.add(const Duration(seconds: 60));
      a.touch();
      await a.pause('background');
      now = now.add(const Duration(hours: 1));
      a.resume();
      now = now.add(const Duration(seconds: 30));
      await a.close();
      final all = readingTotals([a.snapshot()]);
      expect(all.days, {'2026-09-19': 30000, '2026-09-20': 60000});
      expect(
        readingTotals(
          [a.snapshot()],
          start: DateTime(2026, 9, 20, 0, 5),
          end: DateTime(2026, 9, 20, 0, 30),
        ).milliseconds,
        0,
      );
      expect(
        readingTotals(
          [a.snapshot()],
          start: DateTime(2026, 9, 20, 0, 0, 10),
          end: DateTime(2026, 9, 20, 0, 0, 20),
        ).milliseconds,
        10000,
      );
      expect(readingStreak(all.days, DateTime(2026, 9, 21)).current, 2);
      expect(readingStreak(all.days, DateTime(2026, 9, 22)).current, 0);
    },
  );
  test(
    'manual card survives reindex and membership changes; dates validated',
    () async {
      final dir = await Directory.systemTemp.createTemp('reading-details-'),
          db = AppDatabase(NativeDatabase.memory());
      try {
        final repo = Repository(db), lib = ReadingLibrary(Repository(db));
        final file = File('${dir.path}/Original.txt');
        await file.writeAsString('Текст книги');
        final store = AssetStore(repo, Directory('${dir.path}/managed'));
        final asset = await store.importBook(XFile(file.path));
        await lib.index(store, asset);
        await lib.saveDetails(asset.bookId, {
          'title': 'Ручное название',
          'authors': ['Автор'],
          'series': 'Цикл',
          'seriesNumber': '12',
          'description': 'Описание',
          'cover': 'my-cover.png',
          'startedAt': '2026-09-01',
          'finishedAt': '2026-09-19',
        });
        await lib.update('reading-book:${asset.bookId}', {
          'favorite': true,
          'collections': ['one'],
        });
        await lib.index(store, asset, retry: true);
        final info = await lib.bookInfo(
          (await repo.record(asset.bookId))!,
          asset.hash,
        );
        expect(info['title'], 'Ручное название');
        expect(info['cover'], 'my-cover.png');
        expect(info['seriesNumber'], '12');
        expect(info['description'], 'Описание');
        expect(
          (await lib.value('reading-book:${asset.bookId}'))['collections'],
          ['one'],
        );
        await expectLater(
          lib.saveDetails(asset.bookId, {
            'title': 'Bad dates',
            'startedAt': '2026-09-19',
            'finishedAt': '2026-09-01',
          }),
          throwsArgumentError,
        );
        expect(
          (await lib.bookInfo(
            (await repo.record(asset.bookId))!,
            asset.hash,
          ))['title'],
          'Ручное название',
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'Android journal contract uses independent reading directory method',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db), lib = ReadingLibrary(Repository(db));
      const channel = MethodChannel('app.pepehub/audio_folder');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await lib.update('reading-library-root:a', {
        'path': 'content://test/tree/books',
        'bookIds': ['b'],
      });
      final packet = {
        'id': 'session',
        'bookId': 'b',
        'startedAt': DateTime(2026, 9, 19, 12).toUtc().toIso8601String(),
        'spans': [],
        'events': [],
      };
      await lib.update('reading-session:session', packet);
      await ReadingLog(repo).export(packet);
      expect(calls.single.method, 'readingJournal');
      expect(calls.single.arguments['name'], 'reading-2026-09-19.json');
      expect(calls.single.arguments['replace'], true);
    },
  );
  testWidgets('statistics fits phone, goal persists, card edits persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    addTearDown(db.close);
    await repo.addBook('Книга', 'Автор', 'txt');
    final book = (await repo.records('book')).single;
    await repo.addSession(book, 5);
    await tester.runAsync(() async {
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
    final screen = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff326c5c)),
          useMaterial3: true,
        ),
        home: RepaintBoundary(
          key: screen,
          child: ReadingStatisticsPage(repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (screen.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('build/reading-statistics-preview.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
    expect(find.text('5 мин'), findsWidgets);
    expect(find.text('Повторное чтение'), findsOneWidget);
    for (
      var i = 0;
      i < 15 &&
          find
              .byTooltip('Изменить цель чтения')
              .hitTestable()
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('Изменить цель чтения'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '45');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(await repo.meta('reading-daily-goal'), '45');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(
      MaterialApp(
        home: ReadingBookPage(repository: repo, book: book),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Название'),
      'Название вручную',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 15 &&
          find.text('Сохранить карточку').hitTestable().evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -250));
      await tester.pumpAndSettle();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить карточку'));
    await tester.pumpAndSettle();
    expect(
      (await ReadingLibrary(repo).bookInfo(book, null))['title'],
      'Название вручную',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
