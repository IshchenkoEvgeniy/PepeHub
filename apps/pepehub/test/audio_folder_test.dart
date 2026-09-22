import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_import.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'recursive folder scan preserves disc names and filters other files',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-folder-');
      addTearDown(() => root.delete(recursive: true));
      for (final name in [
        'Disc 10/01.MP3',
        'Disc 2/02.flac',
        'Disc 2/01.mp3',
        'cover.jpg',
        'README',
      ]) {
        final file = File('${root.path}/$name');
        await file.parent.create(recursive: true);
        await file.writeAsString('fixture');
      }
      final folder = await scanAudioFolder(root.path);
      folder.files.sort((a, b) => naturalAudioOrder(a.name, b.name));
      expect(folder.files.map((f) => f.name), [
        'Disc 2/01.mp3',
        'Disc 2/02.flac',
        'Disc 10/01.MP3',
      ]);
      expect(await folder.files.first.length(), 7);
      await expectLater(
        scanAudioFolder(root.path, maxFiles: 2),
        throwsStateError,
      );
      await expectLater(
        scanAudioFolder(root.path, maxEntries: 2),
        throwsStateError,
      );
    },
  );

  test(
    'SAF stream closes handle on completion, cancellation and read error',
    () async {
      final calls = <String>[];
      var fail = false;
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioFolderChannel, (call) async {
            calls.add(call.method);
            switch (call.method) {
              case 'open':
                return 'token';
              case 'read':
                if (fail) throw PlatformException(code: 'lost_permission');
                return Uint8List.fromList(reads++ == 0 ? [1, 2, 3] : []);
              case 'close':
                return null;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(audioFolderChannel, null),
      );
      final file = SafAudioFile(
        'content://selected/document',
        'Disc 1/01.mp3',
        3,
      );
      expect(await file.length(), 3);
      expect(await file.openRead().expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
      ]);
      expect(calls, ['open', 'read', 'read', 'close']);
      calls.clear();
      reads = 0;
      await file.openRead().take(1).drain<void>();
      expect(calls, ['open', 'read', 'close']);
      calls.clear();
      fail = true;
      await expectLater(
        file.openRead().drain<void>(),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, ['open', 'read', 'close']);
    },
  );
}
