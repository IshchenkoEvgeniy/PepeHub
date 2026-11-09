import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/shelf_components.dart';

void main() {
  test('format names are shown in Russian', () {
    expect(libraryFormatName('Audiobook'), 'Аудиокнига');
    expect(libraryFormatName('E-book'), 'Электронная книга');
    expect(libraryFormatName('Paper'), 'Бумажная книга');
    expect(libraryFormatName(null), '');
  });

  testWidgets('details panel shows readable rating, format and empty values', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final client = MockClient((_) => throw StateError('Offline'));
    final library = LibraryService(Repository(db), client);
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
    });
    LibraryEntry entry(String id, Map<String, dynamic> values) => LibraryEntry(
      personalLibraryItem(id, 'audiobook', {
        'title': 'Книга $id',
        'status': 'finished',
        'author': ['Автор'],
        ...values,
      }),
    );
    library.entries = [
      entry('rated', {'rating': 7, 'format': 'Audiobook'}),
      entry('blank', {}),
    ];
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.data(Brightness.dark),
        home: ObsidianLibraryPage(
          service: library,
          navigation: ShelfNavigation(
            current: PepeSection.library,
            onSelect: (_) {},
            onSettings: () {},
          ),
          onSettings: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-work:rated')));
    await tester.pumpAndSettle();
    expect(find.text('★ 7'), findsOneWidget);
    expect(find.text('Audiobook'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-work:blank')));
    await tester.pumpAndSettle();
    expect(find.text('Без оценки'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
