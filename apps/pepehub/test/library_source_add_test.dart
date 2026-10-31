import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/ui/library_page.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  for (final format in ['epub', 'audio']) {
    testWidgets(
      'Add to library from the $format file tab opens and saves the editor',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final repo = Repository(db);
        await repo.setMeta(
          'library-section',
          format == 'epub' ? 'reading' : 'audio',
        );
        await repo.addBook('Исходная книга', 'Автор', format);
        await tester.pumpWidget(
          MaterialApp(home: LibraryPage(repository: repo)),
        );
        final state = tester.state(find.byType(LibraryPage)) as dynamic;
        final LibraryService library = state.obsidianLibrary;
        try {
          await ready(
            tester,
            () =>
                find.byTooltip('Действия с книгой').evaluate().isNotEmpty &&
                !library.loading,
          );
          await tester.ensureVisible(find.byTooltip('Действия с книгой').first);
          await tester.tap(find.byTooltip('Действия с книгой').first);
          await ready(
            tester,
            () => find
                .byKey(const ValueKey('book-menu-action:obsidian'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.ensureVisible(find.text('Добавить в библиотеку'));
          await tester.tap(find.text('Добавить в библиотеку'));
          await ready(
            tester,
            () => find.byType(LibraryMetadataEditor).evaluate().isNotEmpty,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Добавить в библиотеку'));
          await ready(
            tester,
            () => find.byType(LibraryMetadataEditor).evaluate().isEmpty,
          );
          expect(library.completed, hasLength(1));
          expect(library.entries, hasLength(1));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(() => library.idle);
          await db.close();
        }
      },
    );
  }
}
