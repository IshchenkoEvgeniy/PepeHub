import 'package:flutter/services.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';

void main() {
  testWidgets(
    'statistics screen fits phone, filters and renders actual aggregates',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final journal = AudioJournal(repo);
      await tester.runAsync(() async {
        final font = File('C:/Windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          final loader = FontLoader('TestUi')
            ..addFont(font.readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }
        final icons = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icons.exists()) {
          final loader = FontLoader('MaterialIcons')
            ..addFont(icons.readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }

        await repo.put('book', 'b', {
          'title': 'Дюна',
          'authors': ['Фрэнк Герберт'],
          'format': 'audio',
          'status': 'active',
        });
        for (var i = 0; i < 12; i++) {
          final date = DateTime.now().subtract(Duration(days: i));
          await journal.put('audio_event', 'test-$i', {
            'kind': 'listen',
            'bookId': 'b',
            'trackId': 't',
            'positionMs': i * 1800000,
            'endMs': (i + 1) * 1800000,
            'wallMs': 1200000,
            'speed': 1.5,
            'at': date.toUtc().toIso8601String(),
            'localDay': dayKey(date),
            'offsetMinutes': date.timeZoneOffset.inMinutes,
          });
        }
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'TestUi',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff26765e),
            ),
            scaffoldBackgroundColor: const Color(0xfff3f6f0),
          ),
          home: RepaintBoundary(
            key: key,
            child: AudioStatisticsPage(repository: repo),
          ),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.text('Пройдено материала').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(
        find.text('Пройдено материала'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      expect(find.text('4 ч 0 мин'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await Directory('build').create();
        await File('build/statistics-phone.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.tap(find.text('1 день'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(find.text('20 мин'), findsWidgets);
      await tester.tap(find.text('Произвольный'));
      await tester.pumpAndSettle();
      expect(find.text('Начало'), findsOneWidget);
      expect(find.text('Конец (не включая)'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7 дней'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final calendar = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('Календарь ·'),
      );
      await tester.scrollUntilVisible(
        calendar,
        350,
        maxScrolls: 40,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(calendar, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('build/statistics-calendar.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.tap(find.byTooltip('Предыдущий месяц'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Сессии прослушивания'),
        350,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
    },
  );
}
