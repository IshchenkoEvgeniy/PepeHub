import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/import_folder.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/reader/reading_book_actions.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/import_folder_page.dart';

import 'video_player_tools_widget_test.dart' show ready;
import 'support/flutter_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, destination;
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late ImportFolder folder;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pepehub-import-folder-');
    destination = await Directory(p.join(temp.path, 'destination')).create();
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    assets = AssetStore(repo, Directory(p.join(temp.path, 'private')));
    folder = ImportFolder(assets);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<XFile> text(String name, String contents) async =>
      XFile((await File(p.join(temp.path, name)).writeAsString(contents)).path);
  Future<XFile> audio(String name, int marker) async => XFile(
    (await File(p.join(temp.path, name)).writeAsBytes([
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
    ])).path,
  );

  test('new text imports use selected folder, preserve source and identity and keep same-name books separate', () async {
    await folder.configure(destination.path);
    final source = await text('Story.txt', 'A book to read.');
    final first = await assets.addBook(source);
    expect(p.isWithin(destination.path, first.path), isTrue);
    expect(await File(first.path).readAsString(), 'A book to read.');
    expect(await File(source.path).exists(), isTrue);
    await repo.setMeta('reader:${first.hash}', '{"chapter":2}');
    final repeated = await assets.addBook(source);
    expect(repeated.bookId, first.bookId);
    expect(repeated.path, first.path);
    final renamed = await assets.addBook(
      await text('Renamed.txt', 'A book to read.'),
    );
    expect(renamed.bookId, first.bookId);
    expect(renamed.path, first.path);
    expect(await repo.meta('reader:${first.hash}'), '{"chapter":2}');
    final other = await assets.importBook(
      await text('story.txt', 'Another book.'),
    );
    expect(other.path.toLowerCase(), isNot(first.path.toLowerCase()));
    expect(await repo.records('book'), hasLength(2));
    expect(await assets.directory.exists(), false);
    expect(
      (await ReadingRoots(assets).list()).single.bookIds,
      containsAll([first.bookId, other.bookId]),
    );
    expect(await repo.meta(personalLibraryKey), isNull);
  });

  test(
    'adds original in place and reuses a file already in the import folder',
    () async {
      final source = await text('original.txt', 'A book to read in place.');
      final added = await assets.addBook(source);
      expect(added.path, source.path);
      expect(await assets.directory.exists(), false);
      expect(await repo.meta(personalLibraryKey), isNull);
      await repo.setMeta('reader:${added.hash}', '{"chapter":3}');
      final nested = await Directory(p.join(destination.path, 'Series'))
          .create();
      final inside = await File(source.path)
          .copy(p.join(nested.path, source.name));
      await folder.configure(destination.path);
      final reused = await assets.addBook(XFile(inside.path));
      expect(reused.path, inside.path);
      expect(reused.bookId, added.bookId);
      expect(await repo.meta('reader:${added.hash}'), '{"chapter":3}');
      expect(
        await destination.list(recursive: true).where((f) => f is File).length,
        1,
      );
      expect(await assets.directory.exists(), false);
      await folder.clear();
      final directAgain = await assets.addBook(source);
      expect(directAgain.path, source.path);
      expect(directAgain.bookId, added.bookId);
    },
  );

  test(
    'SAF text uses the original URI without a staged file or reading cache',
    () async {
      const uri = 'content://test/document/original.txt';
      final bytes = Uint8List.fromList(utf8.encode('Read from the original.'));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var read = false;
      messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
        switch (call.method) {
          case 'open':
            expect(call.arguments['uri'], uri);
            read = false;
            return 'handle';
          case 'read':
            if (read) return null;
            read = true;
            return bytes;
          case 'close':
            return null;
          default:
            throw StateError('Unexpected native call ${call.method}');
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(audioFolderChannel, null),
      );
      final document = SafAudioFile(uri, 'original.txt', -1);
      await expectLater(
        assets.addBook(document, persistent: false),
        throwsStateError,
      );
      final saved = await assets.addBook(document);
      expect(saved.path, uri);
      expect(saved.bytes, bytes.length);
      final data = await readLinkedTextBook(
        SafAudioFile(saved.path, saved.filename, saved.bytes),
        saved.hash,
      );
      expect(data, bytes);
      await loadTextBook(saved.path, saved.filename, sourceBytes: data);
      expect(await assets.directory.exists(), false);
    },
  );

  test('copying old imports preserves history, writes logs, excludes connected sources and is repeatable', () async {
    final old = await assets.importBook(
      await text('old.txt', 'Previously imported text.'),
    );
    final connected = await Directory(p.join(temp.path, 'connected')).create();
    await File(p.join(connected.path, 'external.txt'))
        .writeAsString('External text.');
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(connected.path, books: true));
    await repo.put('session', 'manual', {
      'kind': 'reading',
      'bookId': old.bookId,
      'startedAt': '2026-11-04T10:00:00Z',
      'endedAt': '2026-11-04T10:01:00Z',
      'activeSeconds': 60,
    });
    await repo.setMeta('reader:${old.hash}', '{"chapter":3}');
    await repo.setMeta('reading-note:quote', '{"quote":"Keep this quote"}');
    await folder.configure(destination.path);
    expect((await folder.candidates()), [old.bookId]);
    expect(await folder.copyExisting(), 1);
    final moved = (await assets.byHash(old.hash))!;
    expect(moved.id, old.id);
    expect(moved.bookId, old.bookId);
    expect(await File(old.path).exists(), isTrue);
    expect(await repo.meta('reader:${old.hash}'), '{"chapter":3}');
    expect(
      await repo.meta('reading-note:quote'),
      '{"quote":"Keep this quote"}',
    );
    expect((await repo.record('manual'))!.payload!['activeSeconds'], 60);
    final logs =
        await Directory(p.join(destination.path, '.pepehub', 'reading', 'logs'))
            .list(recursive: true)
            .where((e) => e is File && e.path.endsWith('.json'))
            .toList();
    expect(logs, hasLength(1));
    expect(
      (jsonDecode(await File(logs.single.path).readAsString())['manualSessions']
              as List)
          .single['id'],
      'manual',
    );
    expect(await folder.copyExisting(), 1);
    expect((await assets.byHash(old.hash))!.path, moved.path);
    expect(await repo.records('book'), hasLength(2));
    expect(await repo.meta(personalLibraryKey), isNull);
  });

  test('text import destination does not redirect audiobooks or include them in migration', () async {
    await folder.configure(destination.path);
    final file = await audio('first.mp3', 1);
    final imported = await assets.importAudioBook([file], title: 'Аудиокнига');
    expect(p.isWithin(assets.directory.path, imported.path), isTrue);
    expect(await folder.candidates(), isEmpty);
    expect(await AudioRoots(assets).list(), isEmpty);
    expect(await folder.copyExisting(), 0);
  });

  test('permanent deletion removes both imported copies and refresh does not resurrect the book', () async {
    final source = await text('deleted.txt', 'Delete imported copies only.');
    final old = await assets.importBook(source);
    await folder.configure(destination.path);
    await folder.copyExisting();
    final saved = (await assets.byHash(old.hash))!;
    await ReadingBookActions(assets).deleteForever(old.bookId);
    expect(await File(saved.path).exists(), isFalse);
    expect(await File(old.path).exists(), isFalse);
    expect(await File(source.path).exists(), isTrue);
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(destination.path, books: true));
    expect(await repo.meta('reading-deleted:${old.bookId}'), '1');
    expect(await folder.candidates(), isEmpty);
  });

  test('Android destination publishes verified files through SAF without changing book identity', () async {
    const root = 'content://test/tree/imports';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final local = LocalPeerFiles(destination);
    final stages = <String, PeerStagingFile>{};
    messenger.setMockMethodCallHandler(peerFilesChannel, (call) async {
      final args = call.arguments as Map;
      expect(args['root'], root);
      final path = args['path'] as String?;
      PeerStagingFile stage() => stages[path]!;
      switch (call.method) {
        case 'check':
          return null;
        case 'hash':
          return local.hash(path!);
        case 'locate':
          return 'content://test/tree/imports/document/${Uri.encodeComponent(path!)}';
        case 'stage_reset':
          final hash = (args['stage'] as String).split('-').last;
          stages[path!] = await local.stage(
            PeerFileEntry(
              path: path,
              hash: hash,
              bytes: 0,
              clock: const {'00000000-0000-4000-8000-000000000001': 1},
            ),
          );
          await stage().reset();
          return null;
        case 'stage_append':
          await stage().append(
            args['offset'] as int,
            (args['bytes'] as List).cast<int>(),
          );
          return null;
        case 'stage_hash':
          return stage().hash();
        case 'stage_publish':
          await stage().publish(null);
          return null;
        case 'stage_discard':
          await stage().discard();
          return null;
        default:
          throw StateError('Unexpected method ${call.method}');
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(peerFilesChannel, null),
    );
    await folder.configure(root);
    final imported = await assets.importBook(
      await text('android.txt', 'SAF imported text.'),
    );
    expect(imported.path, startsWith('content://'));
    expect((await assets.byHash(imported.hash))!.bookId, imported.bookId);
    expect((await ReadingRoots(assets).list()).single.path, root);
    final files = await destination.list().where((f) => f is File).toList();
    expect(files, hasLength(1));
    expect(await File(files.single.path).readAsString(), 'SAF imported text.');
  });

  test(
    '1000 books and 1000 audiobooks use headers only to find text imports',
    () async {
      final log = <String>[];
      await runZoned(
        () async {
          final largeDb = AppDatabase(
            NativeDatabase.memory(logStatements: true),
          );
          try {
            final largeRepo = Repository(largeDb);
            await largeDb.transaction(() async {
              for (var i = 0; i < 1000; i++) {
                for (final format in ['epub', 'audio']) {
                  final id = '$format-$i';
                  await largeDb.customStatement(
                    'INSERT INTO records VALUES(?,?,1,0,?)',
                    [
                      id,
                      'book',
                      jsonEncode({'title': id, 'format': format}),
                    ],
                  );
                  await largeRepo.setMeta('reading-imported:$id', '1');
                }
              }
              await largeRepo.setMeta(
                'reading-index:large',
                jsonEncode({
                  'paragraphStarts': List.generate(100000, (i) => i),
                }),
              );
            });
            log.clear();
            final ids = await ImportFolder(
              AssetStore(largeRepo, Directory('unused-import-catalog')),
            ).candidates();
            expect(ids, hasLength(1000));
            expect(ids.every((id) => id.startsWith('epub-')), isTrue);
            final statements = log.join('\n');
            expect(statements, isNot(contains('audio_tracks')));
            expect(statements, isNot(contains('reading-index:large')));
            expect(
              statements,
              isNot(contains('SELECT key,value FROM metadata')),
            );
          } finally {
            await largeDb.close();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => log.add(line),
        ),
      );
    },
  );
  test(
    'unavailable destination and changed target never overwrite source data',
    () async {
      await folder.configure(destination.path);
      final source = await text('source.txt', 'Original file.');
      final imported = await assets.importBook(source);
      await File(imported.path).writeAsString('Tampered file.');
      await expectLater(assets.importBook(source), throwsStateError);
      expect(await File(source.path).readAsString(), 'Original file.');
      expect(await File(imported.path).readAsString(), 'Tampered file.');
      final missing = p.join(temp.path, 'missing');
      await expectLater(folder.configure(missing), throwsStateError);
      expect(await folder.load(), destination.path);
      await destination.rename(p.join(temp.path, 'renamed'));
      await expectLater(
        assets.importBook(await text('new.txt', 'New text.')),
        throwsStateError,
      );
      expect(await repo.records('book'), hasLength(1));
    },
  );

  testWidgets(
    'folder setting is usable on a narrow screen and survives reopening',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundary = GlobalKey();
      if (const bool.fromEnvironment('IMPORT_FOLDER_SCREENSHOT')) {
        await tester.runAsync(() async {
          for (final family in ['Onest', 'Oswald', 'CormorantGaramond']) {
            await (FontLoader(family)..addFont(
                  File('assets/fonts/$family.ttf')
                      .readAsBytes()
                      .then(ByteData.sublistView),
                ))
                .load();
          }
          await (FontLoader('MaterialIcons')..addFont(
                File(materialIconsFont)
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
        });
      }
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: RepaintBoundary(
              key: boundary,
              child: ImportFolderPage(
                key: UniqueKey(),
                assets: assets,
                pick: () async => destination.path,
              ),
            ),
          ),
        );
        await ready(
          tester,
          () =>
              tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('choose-import-folder')),
                  )
                  .onPressed !=
              null,
        );
      }

      await open();
      await tester.tap(find.byKey(const ValueKey('choose-import-folder')));
      await ready(
        tester,
        () => find.text(destination.path).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await open();
      expect(find.text(destination.path), findsOneWidget);
      if (const bool.fromEnvironment('IMPORT_FOLDER_SCREENSHOT')) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('build/import-folder-phone.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
