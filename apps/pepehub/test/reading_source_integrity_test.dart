import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_roots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary, source;
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late ReadingRoots roots;
  late List<List<int>> chunks;
  late int opens, reads, closes;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('reading-integrity-');
    source = await Directory(p.join(temporary.path, 'source')).create();
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    assets = AssetStore(repo, Directory(p.join(temporary.path, 'managed')));
    roots = ReadingRoots(assets);
    chunks = [];
    opens = reads = closes = 0;
    messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
      switch (call.method) {
        case 'open':
          opens++;
          return 'handle';
        case 'read':
          final index = reads++;
          return Uint8List.fromList(index < chunks.length ? chunks[index] : []);
        case 'close':
          closes++;
          return null;
        case 'supportFiles':
          return [];
        default:
          throw StateError('Unexpected platform call: ${call.method}');
      }
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(audioFolderChannel, null);
    await db.close();
    await temporary.delete(recursive: true);
  });

  LocalAsset safAsset({
    int bytes = 4,
    String filename = 'story.txt',
    String? hash,
  }) => LocalAsset(
    id: 'asset',
    bookId: 'book',
    filename: filename,
    path: 'content://books/tree/root/document/story',
    hash: hash ?? sha256.convert([1, 2, 3, 4]).toString(),
    bytes: bytes,
  );
  Future<List<FileSystemEntity>> cachedFiles() async =>
      await assets.directory.exists()
      ? assets.directory.list(recursive: true).where((e) => e is File).toList()
      : [];
  Future<File> story() =>
      File(p.join(source.path, 'story.txt')).writeAsString('A book to read');
  Future<ReadingRoot> connect() async =>
      roots.connect(await scanAudioFolder(source.path, books: true));
  Future<void> keepHistory(LocalAsset asset) async {
    await repo.setMeta(
      'reader:${asset.hash}',
      jsonEncode({'chapter': 0, 'paragraph': 2}),
    );
    await ReadingLibrary(repo).saveNote(
      ReadingNote(
        id: 'note',
        bookId: asset.bookId,
        hash: asset.hash,
        bookTitle: 'Story',
        chapterTitle: 'Chapter',
        quote: 'book',
        comment: 'Keep this thought',
        color: 'yellow',
        updated: '2026-10-13T10:00:00.000Z',
        chapter: 0,
        start: 2,
        end: 6,
      ),
    );
  }

  Future<void> expectHistory(LocalAsset asset) async {
    expect(
      (await ReadingLibrary(repo).value('reader:${asset.hash}'))['paragraph'],
      2,
    );
    final note = (await ReadingLibrary(repo).notes(bookIds: {asset.bookId}))
        .single;
    expect(note.id, 'note');
    expect(note.comment, 'Keep this thought');
    expect(await repo.records('book'), hasLength(1));
  }

  test('SAF stops on the first oversized chunk, closes the handle and removes partial data', () async {
    chunks = [
      [1, 2, 3, 4],
      [5, 6, 7, 8],
      [9],
    ];
    await expectLater(roots.forReading(safAsset()), throwsStateError);
    expect(opens, 1);
    expect(reads, 2);
    expect(closes, 1);
    expect(await cachedFiles(), isEmpty);
  });

  test(
    'invalid declared sizes fail before opening SAF or creating a cache',
    () async {
      for (final asset in [
        safAsset(bytes: 0),
        safAsset(bytes: -1),
        safAsset(bytes: 64 * 1024 * 1024 + 1),
        safAsset(filename: 'story.pdf', bytes: 256 * 1024 * 1024 + 1),
      ]) {
        await expectLater(roots.forReading(asset), throwsStateError);
      }
      expect(opens, 0);
      expect(await assets.directory.exists(), false);
    },
  );

  test(
    'truncated SAF data and changed content leave no readable or partial cache',
    () async {
      for (final bytes in [
        [1, 2],
        [4, 3, 2, 1],
      ]) {
        chunks = [bytes];
        reads = 0;
        await expectLater(roots.forReading(safAsset()), throwsStateError);
        expect(await cachedFiles(), isEmpty);
      }
      expect(opens, 2);
      expect(closes, 2);
    },
  );

  test('a verified SAF cache retains identity and is reused without reading the provider again', () async {
    chunks = [
      [1, 2],
      [3, 4],
    ];
    final original = safAsset();
    final cached = await roots.forReading(original);
    expect(cached.id, original.id);
    expect(cached.bookId, original.bookId);
    expect(cached.hash, original.hash);
    expect(await File(cached.path).readAsBytes(), [1, 2, 3, 4]);
    expect((await roots.forReading(original)).path, cached.path);
    expect(opens, 1);
    expect(closes, 1);
    expect(await cachedFiles(), hasLength(1));
  });

  test(
    'a SAF reading cache does not become an independent import on disconnect',
    () async {
      chunks = [
        [1, 2, 3, 4],
      ];
      final root = await roots.connect(
        AudioFolder('Books', [
          SafAudioFile(safAsset().path, 'story.txt', 4),
        ], root: 'content://books/tree/root'),
      );
      reads = 0;
      final asset = (await assets.list()).single;
      final cached = await roots.forReading(asset);
      await roots.disconnect(root);
      expect(await repo.meta('reading-library-hidden:${asset.bookId}'), '1');
      expect(await repo.meta('reading-imported:${asset.bookId}'), isNull);
      expect((await assets.list()).single.path, asset.path);
      expect(await File(cached.path).exists(), true);
    },
  );

  test('connecting then disconnecting a source keeps an imported copy, notes and progress', () async {
    final file = await story();
    final original = await assets.importBook(XFile(file.path));
    await keepHistory(original);
    final root = await connect();
    final connected = (await assets.list()).single;
    expect(connected.path, original.path);
    expect(connected.id, original.id);
    await file.delete();
    await roots.disconnect(root);
    expect((await assets.list()).single.path, original.path);
    expect(await repo.meta('reading-library-hidden:${original.bookId}'), '0');
    expect(await repo.meta('reading-source-path:${original.bookId}'), isNull);
    expect(await File(original.path).readAsString(), 'A book to read');
    await expectHistory(original);
  });

  test('explicit import promotes an external book without duplicating its identity or history', () async {
    final file = await story();
    final root = await connect();
    final original = (await assets.list()).single;
    await keepHistory(original);
    await roots.disconnect(root);
    expect(await repo.meta('reading-library-hidden:${original.bookId}'), '1');
    final imported = await assets.importBook(XFile(file.path));
    expect(imported.id, original.id);
    expect(imported.bookId, original.bookId);
    expect(assets.isManagedBookPath(imported), true);
    expect(imported.path, isNot(original.path));
    expect(await repo.meta('reading-library-hidden:${original.bookId}'), '0');
    final reconnected = await connect();
    await roots.disconnect(reconnected);
    expect((await assets.list()).single.path, imported.path);
    expect(await repo.meta('reading-library-hidden:${original.bookId}'), '0');
    await expectHistory(imported);
  });

  for (final reconnect in [true, false]) {
    test(
      'an older demoted imported copy is rediscovered on ${reconnect ? 'reconnect' : 'disconnect'}',
      () async {
        final file = await story();
        final original = await assets.importBook(XFile(file.path));
        await keepHistory(original);
        var root = await connect();
        await repo.db.customStatement(
          'UPDATE local_assets SET path=? WHERE id=?',
          [file.path, original.id],
        );
        await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
          'reading-imported:${original.bookId}',
        ]);
        if (reconnect) root = await connect();
        await roots.disconnect(root);
        expect((await assets.list()).single.path, original.path);
        expect(
          await repo.meta('reading-library-hidden:${original.bookId}'),
          '0',
        );
        expect(await repo.meta('reading-imported:${original.bookId}'), '1');
        await expectHistory(original);
      },
    );
  }

  test('reimport refuses to overwrite a corrupt managed file and keeps the source and identity', () async {
    final file = await story();
    final original = await assets.importBook(XFile(file.path));
    await File(original.path).writeAsString('Broken data');
    await expectLater(assets.importBook(XFile(file.path)), throwsStateError);
    expect(await File(original.path).readAsString(), 'Broken data');
    expect(await file.readAsString(), 'A book to read');
    expect((await assets.list()).single.id, original.id);
    expect(
      await assets.directory
          .list()
          .where((e) => e.path.endsWith('.part'))
          .toList(),
      isEmpty,
    );
  });
}
