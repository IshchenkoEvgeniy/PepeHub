import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_folder.dart';

void main() {
  test('reading roots isolate formats and retain identity after rename and reconnect', () async {
    final dir = await Directory.systemTemp.createTemp('reading-roots-');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    addTearDown(() => dir.delete(recursive: true));
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${dir.path}/managed'));
    final roots = ReadingRoots(assets);
    final text = await File('${dir.path}/story.txt')
        .writeAsString('A book to read');
    await File('${dir.path}/chapter.mp3').writeAsBytes([1, 2, 3]);
    final support = Directory('${dir.path}/.pepehub');
    await support.create();
    await File('${support.path}/log.txt').writeAsString('ignore');
    expect((await scanAudioFolder(dir.path)).files.single.name, 'chapter.mp3');
    final root = await roots.connect(
      await scanAudioFolder(dir.path, books: true),
    );
    expect(root.bookIds, hasLength(1));
    final asset = (await assets.list()).single;
    expect(p.normalize(asset.path), p.normalize(text.path));
    await repo.setMeta('reader:${asset.hash}', 'saved-position');
    await text.rename('${dir.path}/renamed.txt');
    final updated = await roots.connect(
      await scanAudioFolder(dir.path, books: true),
    );
    expect(updated.bookIds, root.bookIds);
    expect((await assets.list()).single.path, endsWith('renamed.txt'));
    expect(await repo.meta('reader:${asset.hash}'), 'saved-position');
    expect(await AudioRoots(assets).list(), isEmpty);
    await roots.disconnect(updated);
    expect(await repo.meta('reading-library-hidden:${asset.bookId}'), '1');
    expect(await File('${dir.path}/renamed.txt').exists(), isTrue);
    await roots.connect(await scanAudioFolder(dir.path, books: true));
    expect(await repo.meta('reading-library-hidden:${asset.bookId}'), '0');
    expect(await repo.records('book'), hasLength(1));
  });

  test('invalid scan fails without a partially registered library', () async {
    final dir = await Directory.systemTemp.createTemp('reading-atomic-');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    addTearDown(() => dir.delete(recursive: true));
    final repo = Repository(db);
    final good = await File('${dir.path}/good.txt').writeAsString('valid');
    final bad = await File('${dir.path}/empty.txt').writeAsString('');
    final roots = ReadingRoots(
      AssetStore(repo, Directory('${dir.path}/managed')),
    );
    await expectLater(
      roots.connect(
        AudioFolder('Books', [
          FolderAudioFile(good.path, 'good.txt'),
          FolderAudioFile(bad.path, 'empty.txt'),
        ], root: dir.path),
      ),
      throwsStateError,
    );
    expect(await repo.records('book'), isEmpty);
    expect(await roots.list(), isEmpty);
  });
}
