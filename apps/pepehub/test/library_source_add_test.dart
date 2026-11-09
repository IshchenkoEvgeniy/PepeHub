import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/ui/library_page.dart';
import 'package:pepehub/ui/library_metadata_editor.dart';
import 'package:pepehub/ui/library_work_page.dart';

import 'library_series_add_test.dart' show volume;

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  for (final format in ['epub', 'audio']) {
    testWidgets(
      'linked unread $format opens its series card without changing status',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        final repo = Repository(db);
        await repo.setMeta(
          'library-section',
          format == 'epub' ? 'reading' : 'audio',
        );
        await repo.addBook('Новый том', 'Автор', format);
        final source = (await repo.records('book')).single;
        await repo.setMeta(
          personalLibraryKey,
          jsonEncode({
            'unread-linked': LibraryEntry(
              volume(
                'unread-linked',
                type: format == 'audio' ? 'audiobook' : 'book',
                values: {'status': 'unread', 'pepehub_auto_discovered': false},
              ),
              sourceBookId: source.id,
            ).toJson(),
          }),
        );
        await tester.pumpWidget(
          MaterialApp(home: LibraryPage(repository: repo)),
        );
        final dynamic state = tester.state(find.byType(LibraryPage));
        final LibraryService library = state.personalLibrary;
        try {
          await ready(
            tester,
            () =>
                !library.loading &&
                find.byTooltip('Действия с книгой').evaluate().isNotEmpty,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byTooltip('Действия с книгой').first);
          await tester.tap(find.byTooltip('Действия с книгой').first);
          await ready(
            tester,
            () => find.text('Карточка серии').evaluate().isNotEmpty,
          );
          await tester.ensureVisible(find.text('Карточка серии'));
          await tester.tap(find.text('Карточка серии'));
          await ready(
            tester,
            () => find.byType(LibraryWorkPage).evaluate().isNotEmpty,
          );
          expect(find.byType(LibraryMetadataEditor), findsNothing);
          expect(
            library.unreadSeriesEntries.single.item.value('status'),
            'unread',
          );
          expect(library.completed, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(() => library.idle);
          await db.close();
        }
      },
    );
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
        final LibraryService library = state.personalLibrary;
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
