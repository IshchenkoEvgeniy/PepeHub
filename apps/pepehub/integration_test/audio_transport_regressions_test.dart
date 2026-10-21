import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_controller.dart';

import 'native_audio_test.dart' show silentWav;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native transport preserves Stop, queue, speed and timer resume',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('PepeHub · проверка аудиоплеера')),
          ),
        ),
      );
      final root = await Directory.systemTemp.createTemp(
        'pepehub-audio-audit-',
      );
      final db = AppDatabase(NativeDatabase.memory());
      final repository = Repository(db);
      AudioController? audio;
      try {
        final first = File('${root.path}/1.wav'),
            second = File('${root.path}/2.wav');
        await first.writeAsBytes(silentWav(seconds: 3));
        await second.writeAsBytes(silentWav(seconds: 20));
        final assets = AssetStore(
          repository,
          Directory('${root.path}/managed'),
        );
        final asset = await assets.connectAudioFolder(
          [XFile(first.path), XFile(second.path)],
          root: root.path,
          title: 'Audit',
        );
        audio = await AudioController.create(assets);
        await audio.player.setVolume(0);
        await audio.open(asset, 'Audit');
        await audio.scanDurations();
        expect(audio.error, isEmpty);
        expect(audio.bookDuration?.inSeconds, 23);

        await audio.seekBook(const Duration(seconds: 7));
        await audio.setSpeed(1.5);
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await audio.systemHandler.stop();
        final stopped = audio.position.inMilliseconds;
        expect(audio.player.processingState, ProcessingState.idle);
        expect(audio.canPlay, true);
        expect(stopped, inInclusiveRange(3900, 5000));
        expect(audio.speed, 1.5);
        await audio.systemHandler.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(audio.playing, true);
        expect(audio.trackIndex, 1);
        expect(
          audio.position.inMilliseconds,
          inInclusiveRange(stopped - 150, stopped + 1000),
        );
        expect(audio.speed, 1.5);
        await audio.pause();

        await audio.setSpeed(1);
        await audio.seekBook(const Duration(seconds: 2));
        await audio.play();
        await audio.fastForward();
        expect(audio.trackIndex, 1);
        expect(audio.playing, true);
        await audio.rewind();
        expect(audio.trackIndex, 0);
        expect(audio.playing, true);
        await audio.pause();
        final saved = await audio.audioLibrary.progressForTrack(asset.id);
        expect(saved.locator.trackId, audio.current!.id);
        expect(saved.locator.positionMs, inInclusiveRange(1800, 2900));

        audio.setSleepTimer(0);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (!(audio.player.processingState == ProcessingState.idle &&
                audio.canPlay) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(audio.error, isEmpty);
        expect(audio.sleepMode, 'off');
        expect(audio.player.processingState, ProcessingState.idle);
        expect(audio.canPlay, true);
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(audio.playing, true);
        expect(audio.trackIndex, 0);
        expect(audio.position.inMilliseconds, lessThan(1000));
        expect(audio.error, isEmpty);
        await audio.pause();
        debugPrint(
          'Native audio audit verified: Stop/Play, cross-file seeks, speed, persistence and timer rewind. Isolated silence fixtures only.',
        );
      } finally {
        await audio?.shutdown();
        await db.close();
        final actual = await root.resolveSymbolicLinks();
        final temporary = await Directory.systemTemp.resolveSymbolicLinks();
        if (!actual.toLowerCase().startsWith(
              '${temporary.toLowerCase()}${Platform.pathSeparator}',
            ) ||
            !root.uri.pathSegments
                .where((v) => v.isNotEmpty)
                .last
                .startsWith('pepehub-audio-audit-')) {
          throw StateError('Unexpected test cleanup path');
        }
        await root.delete(recursive: true);
      }
    },
  );
}
