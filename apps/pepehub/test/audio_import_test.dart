import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_import.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/ui/audio_import_dialog.dart';
import 'package:pepehub/ui/audio_catalog_dialog.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late Repository repository;
  late AssetStore assets;
  Future<XFile> fixture(String name, int marker) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes([
      73,
      68,
      51,
      4,
      0,
      0,
      0,
      0,
      0,
      0,
      ...List.filled(1024, marker),
    ]);
    return XFile(file.path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pepehub-multitrack-');
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
    assets = AssetStore(repository, Directory('${root.path}/managed'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  testWidgets('catalog preview fits a phone and separates book folders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AudioCatalogDialog(
                  assets: assets,
                  folder: AudioFolder('книги', [
                    FolderAudioFile('a.mp3', 'Book A/01.mp3'),
                    FolderAudioFile('b.mp3', 'Book B/01.mp3'),
                  ], root: '/library'),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Найдено книг: 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });

  test('natural order handles long numbers and uses deterministic ties', () {
    final names = ['10.mp3', '2.mp3', '1.mp3', '999999999999999999999999.mp3'];
    names.sort(naturalAudioOrder);
    expect(names, ['1.mp3', '2.mp3', '10.mp3', '999999999999999999999999.mp3']);
    expect(naturalAudioOrder('02.mp3', '2.mp3'), lessThan(0));
  });

  test(
    'folder import keeps relative labels and reads original streams',
    () async {
      final first = await fixture('first.mp3', 1);
      final second = await fixture('second.mp3', 2);
      final asset = await assets.importAudioBook([
        FolderAudioFile(first.path, 'Disc 1/01.mp3'),
        FolderAudioFile(second.path, 'Disc 2/01.mp3'),
      ], title: 'Folder book');
      final tracks = await assets.audioTracks(asset.bookId);
      expect(tracks.map((t) => t.filename), ['Disc 1/01.mp3', 'Disc 2/01.mp3']);
      expect(
        await File(tracks.first.path).readAsBytes(),
        await first.readAsBytes(),
      );
      expect(await File(first.path).exists(), isTrue);
    },
  );

  test('whole manifest is atomic, ordered, deduplicated and can repair missing bytes', () async {
    final files = [await fixture('2.mp3', 2), await fixture('1.mp3', 1)];
    final first = await assets.importAudioBook(files, title: 'Два трека');
    final tracks = await assets.audioTracks(first.bookId);
    expect(tracks.map((t) => t.filename), ['2.mp3', '1.mp3']);
    expect(await repository.records('book'), hasLength(1));
    expect(await repository.pendingCount(), 1);
    expect(
      (await AudioLibraryRepository(db).progressForTrack(tracks.last.id))
          .locator
          .trackId,
      tracks.first.id,
    );
    final library = AudioLibraryRepository(db),
        initial = (await AudioLibraryRepository(db).progressForTrack(first.id))
            .locator;
    await library.saveProgress(
      AudioProgress(
        AudioLocator(
          bookId: first.bookId,
          editionId: initial.editionId,
          trackId: tracks.last.id,
          positionMs: 5000,
          manifestRevision: 1,
        ),
        1.5,
      ),
    );
    await File(tracks.last.path).delete();
    final repeated = await assets.importAudioBook(
      files,
      title: 'Не перезаписывать название',
    );
    expect(repeated.bookId, first.bookId);
    expect((await repository.record(first.bookId))!.title, 'Два трека');
    expect(await File(tracks.last.path).exists(), isTrue);
    expect(
      (await library.progressForTrack(first.id)).locator.trackId,
      tracks.last.id,
    );
    final single = await assets.importAudio(files.first);
    expect(single.bookId, isNot(first.bookId));
    expect(await repository.records('book'), hasLength(2));
    expect(
      await db.customSelect('SELECT * FROM audio_resources').get(),
      hasLength(2),
    );
    expect(await assets.list(), hasLength(3));
  });

  test(
    'invalid later file and cancellation leave no book or temporary files',
    () async {
      final good = await fixture('good.mp3', 1),
          bad = File('${root.path}/bad.mp3');
      await bad.writeAsBytes(List.filled(100, 0));
      await expectLater(
        assets.importAudioBook([good, XFile(bad.path)], title: 'Bad'),
        throwsArgumentError,
      );
      expect(await repository.records('book'), isEmpty);
      expect(await assets.directory.list().toList(), isEmpty);
      final control = AudioImportControl();
      await expectLater(
        assets.importAudioBook(
          [good],
          title: 'Cancel',
          control: control,
          onProgress: (_, _) => control.cancelled = true,
        ),
        throwsA(isA<ImportCancelled>()),
      );
      expect(await repository.pendingCount(), 0);
      expect(await assets.directory.list().toList(), isEmpty);
    },
  );

  test('transaction failure removes newly published unowned bytes', () async {
    final good = await fixture('good.mp3', 1);
    await db.customStatement(
      "CREATE TRIGGER fail_audio BEFORE INSERT ON audio_tracks BEGIN SELECT RAISE(ABORT,'injected failure'); END",
    );
    await expectLater(
      assets.importAudioBook([good], title: 'Rollback'),
      throwsA(anything),
    );
    expect(await repository.records('book'), isEmpty);
    expect(await repository.pendingCount(), 0);
    expect(await assets.directory.list().toList(), isEmpty);
  });

  test(
    'identical Ogg bytes with different extensions use one physical copy',
    () async {
      final one = File('${root.path}/1.ogg'), two = File('${root.path}/2.opus');
      final bytes = 'OggS0123456789'.codeUnits;
      await one.writeAsBytes(bytes);
      await two.writeAsBytes(bytes);
      final asset = await assets.importAudioBook([
        XFile(one.path),
        XFile(two.path),
      ], title: 'Shared resource');
      final tracks = await assets.audioTracks(asset.bookId);
      expect(tracks, hasLength(2));
      expect(tracks.first.path, tracks.last.path);
      expect(await assets.directory.list().toList(), hasLength(1));
    },
  );

  testWidgets('preview supports narrow screen and confirmed manual order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = [XFile('10.mp3'), XFile('2.mp3')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<LocalAsset>(
                context: context,
                builder: (_) => AudioImportDialog(files: files, assets: assets),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Переместить ниже').first);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('10.mp3')).dy,
      lessThan(tester.getTopLeft(find.text('2.mp3')).dy),
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });
}
