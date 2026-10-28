import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_resources.dart';
import 'package:pepehub/reader/reader_controls.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reader_bookmarks_page.dart';
import 'package:pepehub/reader/reading_notes_page.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'reader_annotations_bookmarks_test.dart' show asset, document, select;
import 'reader_improvements_test.dart' show settle, size;

void expectReaderWindowTheme(
  WidgetTester tester,
  Finder finder,
  ThemeData expected,
) {
  final actual = Theme.of(tester.element(finder));
  expect(actual.colorScheme.primary, expected.colorScheme.primary);
  expect(actual.colorScheme.onPrimary, expected.colorScheme.onPrimary);
  expect(actual.colorScheme.surface, expected.colorScheme.surface);
  expect(
    actual.colorScheme.surfaceContainerHigh,
    expected.colorScheme.surfaceContainerHigh,
  );
  expect(actual.colorScheme.onSurface, expected.colorScheme.onSurface);
  expect(actual.scaffoldBackgroundColor, expected.scaffoldBackgroundColor);
  expect(actual.textTheme.bodyMedium?.fontFamily, AppFonts.body);
  expect(actual.dialogTheme, expected.dialogTheme);
  expect(actual.bottomSheetTheme, expected.bottomSheetTheme);
  expect(actual.inputDecorationTheme, expected.inputDecorationTheme);
  expect(actual.filledButtonTheme, expected.filledButtonTheme);
  expect(actual.chipTheme, expected.chipTheme);
  expect(actual.popupMenuTheme, expected.popupMenuTheme);
  expect(actual.extensions, expected.extensions);
}

void main() {
  testWidgets(
    'a new font chosen in the picker survives saving and reopening the book',
    (tester) async {
      size(tester, const Size(430, 900));
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      Widget book() => MaterialApp(
        theme: AppTheme.data(Brightness.dark, style: AppStyle.brass),
        home: ReaderPage(
          repository: repo,
          asset: asset,
          suppliedDocument: document,
        ),
      );
      try {
        await tester.pumpWidget(book());
        await settle(tester);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reader-font')));
        await tester.pumpAndSettle();
        final target = find.text('PT Sans · без засечек').last;
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Готово'));
        await settle(tester);
        expect(
          tester
              .widget<ReaderViewport>(find.byType(ReaderViewport))
              .style
              .fontFamily,
          'ReaderPTSans',
        );
        expect(
          jsonDecode((await repo.meta('reader:appearance'))!)['font'],
          'pt-sans',
        );
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await tester.pumpWidget(book());
        await settle(tester);
        expect(
          tester
              .widget<ReaderViewport>(find.byType(ReaderViewport))
              .style
              .fontFamily,
          'ReaderPTSans',
        );
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byKey(const ValueKey('reader-font')),
              )
              .initialValue,
          'pt-sans',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );
  for (final style in AppStyle.values) {
    final palette = ['light', 'dark', 'sepia'][style.index % 3];
    testWidgets(
      '${style.name} with $palette paper keeps application window styles',
      (tester) async {
        size(tester, const Size(430, 900));
        final db = AppDatabase(NativeDatabase.memory());
        final repo = Repository(db);
        final theme = AppTheme.data(
          Brightness.dark,
          style: style,
          compact: true,
        );
        await repo.setMeta(
          'reader:appearance',
          jsonEncode({'palette': palette, 'mode': 'pages', 'font': 'literata'}),
        );
        Future<void> close() async {
          await tester.binding.handlePopRoute();
          await settle(tester);
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: ReaderPage(
                repository: repo,
                asset: asset,
                suppliedDocument: document,
              ),
            ),
          );
          await settle(tester);
          expect(
            tester
                .widget<ReaderViewport>(find.byType(ReaderViewport))
                .style
                .fontFamily,
            'ReaderLiterata',
          );
          await tester.tap(find.byTooltip('Оформление чтения'));
          await tester.pumpAndSettle();
          expectReaderWindowTheme(
            tester,
            find.text('Оформление чтения'),
            theme,
          );
          final field = find.byKey(const ValueKey('reader-font'));
          expect(
            tester.widget<DropdownButtonFormField<String>>(field).initialValue,
            'literata',
          );
          await close();

          if (style == AppStyle.pine) {
            await tester.tap(find.byTooltip('Оглавление'));
            await tester.pumpAndSettle();
            expectReaderWindowTheme(tester, find.text('Оглавление · 3'), theme);
            await close();
            await tester.tap(find.byTooltip('Поиск по книге'));
            await settle(tester);
            expectReaderWindowTheme(tester, find.byType(ReaderSearch), theme);
            await close();
            await tester.tap(find.byTooltip('Другие действия'));
            await tester.pumpAndSettle();
            expectReaderWindowTheme(
              tester,
              find.text('Горячие клавиши'),
              theme,
            );
            await tester.tap(find.text('Горячие клавиши'));
            await tester.pumpAndSettle();
            expectReaderWindowTheme(tester, find.byType(AlertDialog), theme);
            await close();
            await tester.tap(find.byTooltip('Другие действия'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Закладки'));
            await settle(tester);
            expectReaderWindowTheme(
              tester,
              find.byType(ReaderBookmarksPage),
              theme,
            );
            await tester.tap(find.text('Запомнить текущее место'));
            await tester.pumpAndSettle();
            expectReaderWindowTheme(tester, find.byType(AlertDialog), theme);
            await close();
            await close();
            await tester.tap(find.byTooltip('Заметки книги'));
            await settle(tester);
            expectReaderWindowTheme(
              tester,
              find.byType(ReadingNotesPage),
              theme,
            );
            await close();

            await select(tester, 0, 4);
            expectReaderWindowTheme(tester, find.text('Выделить'), theme);
            await tester.tap(find.text('Заметка'));
            await tester.pumpAndSettle();
            expectReaderWindowTheme(tester, find.byType(AlertDialog), theme);
            await close();
            unawaited(
              showBookFootnote(
                tester.element(find.byType(ReaderViewport)),
                const BookFootnote('[4]', 'Пояснение к книге', 0, 4),
              ),
            );
            await tester.pumpAndSettle();
            expectReaderWindowTheme(tester, find.text('Примечание 4'), theme);
            await close();
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await db.close();
        }
      },
    );
  }
}
