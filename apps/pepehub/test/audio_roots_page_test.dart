import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/folder_scan_progress.dart';
import 'package:pepehub/ui/audio_roots_page.dart';

void main() {
  test('audiobook counts and folder summary read naturally', () {
    expect(audiobookCount(1), '1 аудиокнига');
    expect(audiobookCount(4), '4 аудиокниги');
    expect(audiobookCount(11), '11 аудиокниг');
    final root = AudioRoot('k', {
      'root': '/a',
      'title': 'A',
      'bookIds': ['x', 'y'],
      'lastScan': DateTime(2026, 11, 7, 9).toUtc().toIso8601String(),
      'lastReport': {'supported': 34},
    });
    expect(
      audioRootSummary(root, DateTime(2026, 11, 7, 18)),
      '2 аудиокниги · 34 файлов · проверено сегодня',
    );
  });

  test('cancelled refresh rolls back: the folder stays as it was', () async {
    final temp = await Directory.systemTemp.createTemp('audio-cancel-');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${temp.path}/managed'));
    final roots = AudioRoots(assets);
    try {
      for (final name in ['One', 'Two']) {
        final file = File('${temp.path}/$name/01.mp3');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List.filled(16, 1));
      }
      final folder = await scanAudioFolder(temp.path);
      await connectAudioCatalog(
        assets,
        folder,
        groupAudioCatalog(folder, mode: 'folders'),
        mode: 'folders',
      );
      final before = (await roots.list()).single;
      for (final name in ['Three', 'Four', 'Five']) {
        final file = File('${temp.path}/$name/01.mp3');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List.filled(16, 2));
      }
      final progress = FolderScanProgress('test');
      progress.addListener(() {
        if (progress.phase == 'Обработка книг' && progress.done >= 2) {
          progress.cancel();
        }
      });
      await expectLater(
        roots.refresh(before, progress: progress),
        throwsA(isA<FolderScanCancelled>()),
      );
      final after = (await roots.list()).single;
      expect(jsonEncode(after.data), jsonEncode(before.data));
      expect(await repo.records('book'), hasLength(2));
      expect(progress.total, 5);
      expect(progress.unit, 'книг');
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
