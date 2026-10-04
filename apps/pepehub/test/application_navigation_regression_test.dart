import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/ui/audio_import_dialog.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';

const item = ObsidianLibraryItem(
  id: 'd1d2d3d4-1234-4123-8123-123456789abc',
  path: 'Books/Book.md',
  collectionId: 'book',
  mediaType: 'book',
  values: {'Title': 'Book'},
  fields: [LibraryField('Title', 'title', 'text')],
);

void main() {
  testWidgets('two rapid connect taps start only one audio import', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final assets = _PendingAssets(Repository(db));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<LocalAsset>(
                context: context,
                builder: (_) => AudioImportDialog(
                  assets: assets,
                  files: [XFile('Track.mp3')],
                  sourceRoot: 'Audio',
                ),
              ),
              child: const Text('Open import'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подключить'));
    await tester.tap(find.text('Подключить'));
    assets.saved.complete(
      const LocalAsset(
        id: 'track',
        bookId: 'book',
        filename: 'Track.mp3',
        path: 'Track.mp3',
        hash: 'hash',
        bytes: 12,
      ),
    );
    await tester.pumpAndSettle();
    expect(assets.calls, 1);
    expect(find.text('Open import'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two rapid save taps submit Obsidian metadata only once', (
    tester,
  ) async {
    final saved = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryMetadataEditor(
          item: item,
          onSave: (_) async {
            calls++;
            await saved.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    saved.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'finishing metadata save during back animation leaves the previous screen open',
    (tester) async {
      final saved = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LibraryMetadataEditor(
                      item: item,
                      onSave: (_) => saved.future,
                    ),
                  ),
                ),
                child: const Text('Library screen'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Library screen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      await tester.pageBack();
      saved.complete();
      await tester.pumpAndSettle();
      expect(find.text('Library screen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PendingAssets extends AssetStore {
  _PendingAssets(Repository repository) : super(repository, Directory('.'));
  final saved = Completer<LocalAsset>();
  int calls = 0;
  @override
  Future<LocalAsset> connectAudioFolder(
    List<XFile> files, {
    required String root,
    required String title,
    String? replaceBookId,
  }) async {
    calls++;
    return saved.future;
  }
}
