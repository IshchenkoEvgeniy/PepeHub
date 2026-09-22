import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/media/audio_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'finds cover above Disc folder, caches and persists replacement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pepehub-cover-cache-',
      );
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 4, 4),
          ui.Paint()..color = const ui.Color(0xff118855),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final bytes = data!.buffer.asUint8List();
        await Directory('${root.path}/Book/Disc 1').create(recursive: true);
        final audio = File('${root.path}/Book/Disc 1/01.mp3');
        await audio.writeAsBytes([1, 2, 3]);
        await File('${root.path}/Book/cover.png').writeAsBytes(bytes);
        final assets = AssetStore(
          Repository(db),
          Directory('${root.path}/cache'),
        );
        final track = await assets.connectAudioFolder(
          [XFile(audio.path)],
          root: '${root.path}/Book',
          title: 'Book',
        );
        final store = ArtworkStore(assets);
        final first = await store.load(track.bookId);
        expect(first, isNotNull);
        expect(File.fromUri(first!).path, contains('cache'));
        final selected = await store.save(track.bookId, bytes);
        expect(selected, isNot(first));
        expect(await ArtworkStore(assets).load(track.bookId), selected);
        await expectLater(
          store.save(track.bookId, Uint8List.fromList([1, 2, 3])),
          throwsA(anything),
        );
        expect(await store.load(track.bookId), selected);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('prefers cover and ignores audio and directories', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-art-');
    try {
      await File('${root.path}/01.mp3').writeAsString('audio');
      await File('${root.path}/other.jpg').writeAsString('image');
      await File('${root.path}/COVER.PNG').writeAsString('image');
      await Directory('${root.path}/cover.jpg').create();
      expect(
        await findAudioArtwork('${root.path}/01.mp3'),
        File('${root.path}/COVER.PNG').uri,
      );
      expect(await findAudioArtwork('${root.path}/missing/01.mp3'), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('SAF artwork retains URI; denied access is optional', () async {
    const channel = MethodChannel('app.pepehub/audio_folder');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'cover');
      return 'content://books/tree/root/document/cover';
    });
    expect(
      (await findAudioArtwork('content://books/audio'))?.scheme,
      'content',
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'permission'),
    );
    expect(await findAudioArtwork('content://books/audio'), isNull);
    messenger.setMockMethodCallHandler(channel, null);
  });
}
