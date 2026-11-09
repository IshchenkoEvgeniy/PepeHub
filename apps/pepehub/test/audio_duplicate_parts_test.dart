import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/ui/library_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

/// The same audiobook connected twice: split into numbered parts by one
/// folder and as a single book by another (overlapping) folder. The whole
/// shelf showed both; a folder view showed only its own books.
void main() {
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late Directory temp;
  late String all, book;

  Future<void> write(String name, String content) async {
    final file = File(p.joinAll([all, ...name.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<void> connect(String path, String mode) async {
    final scan = await scanAudioFolder(path);
    await connectAudioCatalog(
      assets,
      scan,
      groupAudioCatalog(scan, mode: mode),
      mode: mode,
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    temp = await Directory.systemTemp.createTemp('pepehub-duplicate-parts-');
    assets = AssetStore(repo, Directory(p.join(temp.path, 'managed')));
    // Platform separators: the same file must be spelled the same way when
    // it is reached through the outer and the inner folder.
    all = p.join(temp.path, 'Аудио');
    book = p.join(all, 'Цвет волшебства');
    await write('Цвет волшебства/01/a.mp3', 'ID3 part one');
    await write('Цвет волшебства/02/b.mp3', 'ID3 part two');
    await write('Цвет волшебства/03/c.mp3', 'ID3 part three');
    await write('Стрела/x.mp3', 'ID3 another book');
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<Map<String, String>> titles() async => {
    for (final r in await repo.records('book')) r.id: r.title,
  };

  test('unstarted parts are contained in the whole book, by content', () async {
    await connect(all, 'folders');
    await connect(book, 'single');
    final names = await titles();
    final pairs = await AudioLibraryRepository(db).containedBooks();
    final whole = names.entries
        .singleWhere((e) => e.value == 'Цвет волшебства')
        .key;
    expect(pairs.map((p) => p.$2).toSet(), {whole});
    expect(
      pairs.map((p) => names[p.$1]).toSet(),
      hasLength(3),
      reason: 'every numbered part is inside the whole book',
    );
    expect(pairs.map((p) => names[p.$1]), isNot(contains('Стрела')));

    // A started part is the user's own progress: it stays on the shelf.
    final part = pairs.first.$1;
    final library = AudioLibraryRepository(db);
    final track = (await assets.audioTracks(part)).single;
    final progress = await library.progressForTrack(track.id);
    await library.saveProgress(
      AudioProgress(
        AudioLocator(
          bookId: part,
          editionId: progress.locator.editionId,
          trackId: track.id,
          positionMs: 5000,
          manifestRevision: progress.locator.manifestRevision,
        ),
        1,
      ),
    );
    final after = await AudioLibraryRepository(db).containedBooks();
    expect(after.map((p) => p.$1), isNot(contains(part)));
    expect(after, hasLength(2));
  });

  test(
    'an Android document is the same file under any picked folder',
    () async {
      // content://…/tree/<picked folder>/document/<file>: picking «Аудио» or
      // «Аудио/Цвет волшебства» changes the tree, not the document.
      const provider = 'content://com.android.externalstorage.documents';
      String uri(String tree, String doc) =>
          '$provider/tree/${Uri.encodeComponent('primary:$tree')}'
          '/document/${Uri.encodeComponent('primary:$doc')}';
      Future<void> add(String bookId, String tree, List<String> files) async {
        await repo.put('book', bookId, {'title': bookId, 'format': 'audio'});
        await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
          'e-$bookId',
          bookId,
        ]);
        for (final (i, file) in files.indexed) {
          final hash = 'external:$bookId-$i';
          await db.customStatement(
            'INSERT INTO audio_resources VALUES(?,?,?)',
            [hash, uri(tree, file), 10],
          );
          await db.customStatement(
            'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
            ['t-$bookId-$i', 'e-$bookId', hash, i, file, 1000],
          );
        }
      }

      const parts = ['Аудио/Цвет/01/a.mp3', 'Аудио/Цвет/02/b.mp3'];
      await add('whole', 'Аудио/Цвет', parts);
      await add('part-1', 'Аудио', [parts[0]]);
      await add('part-2', 'Аудио', [parts[1]]);
      await add('other', 'Аудио', ['Аудио/Другая/a.mp3']);
      final pairs = await AudioLibraryRepository(db).containedBooks();
      expect(pairs.toSet(), {('part-1', 'whole'), ('part-2', 'whole')});
    },
  );

  testWidgets('the whole shelf shows the book once; a folder keeps its own', (
    tester,
  ) async {
    late Map<String, String> names;
    late List<AudioRoot> roots;
    await tester.runAsync(() async {
      await connect(all, 'folders');
      await connect(book, 'single');
      names = await titles();
      roots = await AudioRoots(assets).list();
      await repo.setMeta('library-section', 'audio');
    });
    // Tall enough that every card is built.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(repository: repo, assets: assets),
      ),
    );
    final dynamic state = tester.state(find.byType(LibraryPage));
    await ready(
      tester,
      () => !state.loading && (state.books as List).isNotEmpty,
    );
    List<String> shown() => [
      for (final b in (state.books as List).cast<dynamic>())
        if (find.byKey(ValueKey('book-card:${b.id}')).evaluate().isNotEmpty)
          names[b.id]!,
    ];
    Future<void> folder(String? key) async {
      state.selectedRoot = key;
      state.setState(() {});
      await tester.pumpAndSettle();
    }

    final parentRoot = roots.singleWhere((r) => r.path.endsWith('Аудио')).key;
    final bookRoot = roots
        .singleWhere((r) => r.path.endsWith('Цвет волшебства'))
        .key;

    // Whole library: the book once, its parts not repeated next to it.
    expect(shown()..sort(), ['Стрела', 'Цвет волшебства']);
    expect(find.byKey(const ValueKey('status-tab:all')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('status-tab:all')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    // The parent folder holds only the parts: they stay listed there.
    await folder(parentRoot);
    expect(shown(), hasLength(4));
    expect(shown(), contains('Стрела'));
    expect(shown(), isNot(contains('Цвет волшебства')));

    // The book's own folder shows the whole book.
    await folder(bookRoot);
    expect(shown(), ['Цвет волшебства']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
