import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/pepe_widgets.dart';
import 'package:pepehub/ui/reading_statistics_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

/// A text book with a file, an indexed length and a cover image.
Future<(Repository, String, String)> seededBook(Directory dir) async {
  final db = AppDatabase(NativeDatabase.memory());
  final repo = Repository(db);
  await repo.addBook('Солярис', 'Лем', 'epub');
  final book = (await repo.records('book')).single;
  final cover = File('${dir.path}/cover.png')
    ..writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ),
    );
  await db.customStatement(
    'INSERT INTO local_assets(id,book_id,filename,path,sha256,bytes) VALUES(?,?,?,?,?,?)',
    ['asset', book.id, 'solaris.epub', '${dir.path}/solaris.epub', 'h', 1],
  );
  await repo.setMeta(
    'reading-index:h',
    jsonEncode({
      'length': 180000,
      'cover': cover.path,
      'starts': [0],
    }),
  );
  await repo.setMeta(
    'reading-coverage:h',
    jsonEncode({
      'ranges': [
        [0, 90000],
      ],
    }),
  );
  // 1 800 characters a minute: one page a minute, 60 pages an hour.
  await repo.setMeta(
    'reading-session:s',
    jsonEncode({
      'bookId': book.id,
      'hash': 'h',
      'startedAt': DateTime.now()
          .subtract(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
      'speedVersion': 1,
      'speedMoves': 5,
      'speedActiveMs': 600000,
      'speedChars': 18000,
      'spans': [],
      'events': [],
    }),
  );
  return (repo, book.id, cover.path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('volume is shown in pages', () {
    expect(pepePages(0), '0 стр.');
    expect(pepePages(500), '< 1 стр.');
    expect(pepePages(216000), '≈ 120 стр.');
    expect(pepePages(1800 * 1500), '≈ 1 500 стр.');
  });

  test('cover paths come from the book index, user covers win', () async {
    final dir = await Directory.systemTemp.createTemp('pepe-covers-');
    addTearDown(() => dir.delete(recursive: true));
    final (repo, id, cover) = await seededBook(dir);
    final library = ReadingLibrary(repo);
    expect(await library.coverPaths(), {id: cover});
    await library.update('reading-book:$id', {
      'overrides': {'cover': '/custom.jpg'},
    });
    expect((await library.coverPaths())[id], '/custom.jpg');
    await repo.db.close();
  });

  testWidgets('book statistics show progress, remaining time and finish', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('pepe-book-stats-'),
    ))!;
    final (repo, id, _) = (await tester.runAsync(() => seededBook(dir)))!;
    await tester.pumpWidget(
      MaterialApp(
        home: ReadingStatisticsPage(repository: repo, bookId: id),
      ),
    );
    final dynamic state = tester.state(find.byType(ReadingStatisticsPage));
    await ready(tester, () => !state.loading && state.forecast != null);
    expect(find.text('50% прочитано'), findsOneWidget);
    // 90 000 characters left at 1 800 a minute: 50 minutes, 50 pages.
    expect(find.text('Осталось ≈ 50 мин'), findsOneWidget);
    expect(find.textContaining('≈ 50 стр. · 60 стр. в час'), findsOneWidget);
    expect(find.textContaining('Закончите ≈'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    // Service details live behind the info button, not on the page.
    expect(find.textContaining('2 минут без действий'), findsNothing);
    await tester.tap(find.byTooltip('О статистике и экспорт журнала'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 минут без действий'), findsOneWidget);
    expect(find.text('Экспорт в папку · Markdown / JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await repo.db.close();
      await dir.delete(recursive: true);
    });
  });
}
