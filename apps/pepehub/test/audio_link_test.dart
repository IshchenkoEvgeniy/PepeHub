import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

class UnreadableSource extends FolderAudioFile {
  final int size;
  UnreadableSource(super.path, super.relativePath, this.size);
  @override
  Future<int> length() async => size;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      throw StateError('Audio bytes must not be read while connecting');
  @override
  Future<Uint8List> readAsBytes() =>
      throw StateError('Audio bytes must not be read while connecting');
}

void main() {
  late AppDatabase db;
  late Repository repository;
  late Directory root;
  late AssetStore assets;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
    root = await Directory.systemTemp.createTemp('audio-links-');
    assets = AssetStore(repository, Directory('${root.path}/managed'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'connect large and unknown-size sources without reading or copying audio',
    () async {
      final asset = await assets.connectAudioFolder(
        [
          UnreadableSource(
            'content://provider/tree/book/document/1',
            'Disc 1/01.m4b',
            50 * 1024 * 1024 * 1024,
          ),
          UnreadableSource(
            'content://provider/tree/book/document/2',
            'Disc 2/01.mp3',
            -1,
          ),
        ],
        root: 'content://provider/tree/book',
        title: 'External book',
      );
      final tracks = await assets.audioTracks(asset.bookId);
      expect(tracks.first.path, 'content://provider/tree/book/document/1');
      expect(tracks.first.hash, startsWith('external:'));
      expect(tracks.last.bytes, 0);
      expect(await root.list().toList(), isEmpty);
      final outbox = await db
          .customSelect('SELECT operation FROM outbox')
          .get();
      expect(
        outbox.map((r) => r.read<String>('operation')).join(),
        isNot(contains('content://')),
      );
      expect(audioSourceUri(tracks.first.path).scheme, 'content');
      expect(audioSourceUri(r'C:\Books\one.mp3').scheme, 'file');
    },
  );

  test(
    'reconnect preserves IDs, order and position; mismatch rolls back',
    () async {
      final files = [
        UnreadableSource('/old/1.mp3', '1.mp3', 20),
        UnreadableSource('/old/2.mp3', '2.mp3', 30),
      ];
      final asset = await assets.connectAudioFolder(
        files,
        root: '/old',
        title: 'Book',
      );
      final before = await assets.audioTracks(asset.bookId);
      final library = AudioLibraryRepository(db);
      final saved = await library.progressForTrack(asset.id);
      await library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: asset.bookId,
            editionId: saved.locator.editionId,
            trackId: before.last.id,
            positionMs: 12000,
            manifestRevision: 1,
          ),
          1.5,
        ),
      );
      final again = await assets.connectAudioFolder(
        files.reversed.toList(),
        root: '/old',
        title: 'Ignored',
      );
      expect(again.bookId, asset.bookId);
      await assets.connectAudioFolder(
        [
          UnreadableSource('/new/2.mp3', '2.mp3', 30),
          UnreadableSource('/new/1.mp3', '1.mp3', 20),
        ],
        root: '/new',
        title: 'Book',
        replaceBookId: asset.bookId,
      );
      final after = await assets.audioTracks(asset.bookId);
      expect(after.map((t) => t.id), before.map((t) => t.id));
      expect(after.map((t) => t.path), ['/new/1.mp3', '/new/2.mp3']);
      final restored = await library.progressForTrack(asset.id);
      expect(restored.locator.trackId, before.last.id);
      expect(restored.locator.positionMs, 12000);
      expect(restored.speed, 1.5);
      await expectLater(
        assets.connectAudioFolder(
          [UnreadableSource('/bad/1.mp3', '1.mp3', 900)],
          root: '/bad',
          title: 'Wrong',
          replaceBookId: asset.bookId,
        ),
        throwsStateError,
      );
      expect((await assets.audioTracks(asset.bookId)).first.path, '/new/1.mp3');
      expect(await repository.records('book'), hasLength(1));
      expect(await root.list().toList(), isEmpty);
    },
  );
}
