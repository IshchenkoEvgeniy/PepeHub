import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/cover_sync.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late Repository local;
  late AssetStore assets;
  final config = ObsidianConfig('https://example.test', 'secret');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pepehub-cover-sync-');
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    assets = AssetStore(local, root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<Uint8List> image(int color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const ui.Rect.fromLTWH(0, 0, 4, 8),
      ui.Paint()..color = ui.Color(color),
    );
    final picture = recorder.endRecording(),
        image = await picture.toImage(4, 8);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  Future<LibraryEntry> linked({
    String? cover,
    Map<String, dynamic>? asset,
  }) async {
    await local.addBook('One', 'Author', 'epub');
    final book = (await local.records('book')).single;
    final item = ObsidianLibraryItem(
      id: uuid.v4(),
      path: 'Books/One.md',
      collectionId: 'book',
      mediaType: 'book',
      values: {'Cover': cover},
      fields: const [LibraryField('Cover', 'cover', 'text')],
      coverAsset: asset,
    );
    final entry = LibraryEntry(item, sourceBookId: book.id);
    await LibraryRepository(local, config.namespace).mutate((entries) async {
      entries[item.id] = entry;
    });
    return entry;
  }

  test(
    'private cover downloads verify hashes and work offline after caching',
    () async {
      final bytes = await image(0xff118855),
          hash = sha256.convert(bytes).toString();
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.origin, 'https://example.test');
        expect(request.headers['Authorization'], 'Bearer secret');
        return http.Response.bytes(bytes, 200);
      });
      final covers = CoverSync(assets, client, config),
          path = await covers.download(hash);
      expect(await File(path).readAsBytes(), bytes);
      expect(await covers.download(hash), path);
      expect(calls, 1);
      final other = CoverSync(
        assets,
        client,
        ObsidianConfig(config.url, 'different'),
      );
      expect(other.path(hash), isNot(path));
      client.close();
      final wrong = MockClient((_) async => http.Response.bytes(bytes, 200));
      await expectLater(
        CoverSync(assets, wrong, config).download('a' * 64),
        throwsStateError,
      );
      wrong.close();
    },
  );
  test('inbound cover fills the linked reader; local edits queue a conflict-safe metadata operation', () async {
    final remote = await image(0xff118855),
        hash = sha256.convert(remote).toString(),
        entry = await linked(
          cover: '[[Images/cover.png]]',
          asset: {'hash': hash, 'bytes': remote.length, 'mime': 'image/png'},
        );
    final client = MockClient(
      (request) async => request.method == 'GET'
          ? http.Response.bytes(remote, 200)
          : http.Response('{}', request.method == 'HEAD' ? 404 : 200),
    );
    final covers = CoverSync(assets, client, config);
    expect(await covers.run(), false);
    final library = ReadingLibrary(local);
    expect(
      (await library.bookInfo(
        (await local.records('book')).single,
        null,
      ))['cover'],
      covers.path(hash),
    );
    expect(await covers.run(), false);
    final changed = File('${root.path}/changed.png');
    await changed.writeAsBytes(await image(0xffcc3311));
    await library.saveDetails(entry.sourceBookId!, {
      'title': 'One',
      'cover': changed.path,
    });
    expect(await covers.run(), true);
    final queued = (await LibraryRepository(
      local,
      config.namespace,
    ).entries())[entry.item.id]!;
    expect(queued.operation!['base'], {'Cover': '[[Images/cover.png]]'});
    expect(queued.operation!['values']['Cover'], startsWith('pepehub-cover:'));
    expect(queued.item.coverAsset, entry.item.coverAsset);
    expect(await covers.run(), false);
    client.close();
  });
  test('bad cover does not stop metadata or journal exchange and does not overwrite native artwork', () async {
    final entry = await linked();
    final file = File('${root.path}/broken.png');
    await file.writeAsString('broken');
    await ReadingLibrary(local)
        .saveDetails(entry.sourceBookId!, {'title': 'One', 'cover': file.path});
    final client = MockClient(
      (_) async => throw StateError('unexpected request'),
    );
    expect(await CoverSync(assets, client, config).run(), false);
    expect(
      await local.meta('obsidian-cover-errors:${config.namespace}'),
      isNotEmpty,
    );
    expect(
      (await LibraryRepository(
        local,
        config.namespace,
      ).entries())[entry.item.id]!.state,
      'synced',
    );
    client.close();
  });
}
