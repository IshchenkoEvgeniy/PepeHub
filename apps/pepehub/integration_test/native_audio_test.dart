import 'package:pepehub/ui/audio_page.dart';
import 'package:pepehub/ui/audio_statistics_page.dart';

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'package:drift/native.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_controller.dart';
import 'package:pepehub/main.dart' as app;
import 'package:pepehub/ui/library_page.dart';

Uint8List silentWav({int seconds = 8}) {
  const sampleRate = 22050;
  final dataSize = sampleRate * seconds * 2;
  final bytes = Uint8List(44 + dataSize), data = ByteData.sublistView(bytes);
  void text(int offset, String value) {
    bytes.setRange(offset, offset + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, dataSize, Endian.little);
  return bytes;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'production startup opens an isolated on-disk database and library',
    (tester) async {
      final startupRoot = await Directory.systemTemp.createTemp(
        'pepehub-startup-test-',
      );
      addTearDown(() async => startupRoot.delete(recursive: true));
      await app.startPepeHub(
        openDatabase: () => AppDatabase.openInDirectory(startupRoot.path),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryPage), findsOneWidget);
      final application = tester.widget<app.PepeHubApp>(
        find.byType(app.PepeHubApp),
      );
      expect(application.audioError, isNull);
      expect(application.audio, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await application.audio?.shutdown();
      await application.repository.db.close();
    },
  );
  testWidgets(
    'native decoder plays generated silence, seeks and persists the session',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('PepeHub · проверка аудио'))),
        ),
      );
      final root = await Directory.systemTemp.createTemp(
        'pepehub-native-test-',
      );
      final db = AppDatabase(NativeDatabase.memory());
      final repository = Repository(db);
      AudioController? audio;
      try {
        final file = File('${root.path}/silence.wav');
        await file.writeAsBytes(silentWav());
        final assets = AssetStore(
          repository,
          Directory('${root.path}/managed'),
        );
        final asset = await assets.importAudio(XFile(file.path));
        final book = (await repository.records('book')).single;
        audio = await AudioController.create(assets);
        await audio.player.setVolume(0);
        await audio.open(asset, book.title);
        expect(audio.error, isEmpty);
        expect(audio.canPlay, isTrue);
        expect(audio.duration.inSeconds, 8);
        expect(audio.mediaItem.value?.title, book.title);
        expect(audio.mediaItem.value?.artist, asset.filename);
        expect(audio.mediaItem.value?.duration?.inSeconds, 8);
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(audio.position.inMilliseconds, greaterThan(500));
        await audio.setSpeed(1.5);
        await audio.seek(const Duration(seconds: 5));
        await audio.pause();
        expect(audio.playbackState.value.playing, isFalse);
        expect(
          audio.playbackState.value.updatePosition.inMilliseconds,
          greaterThanOrEqualTo(4900),
        );
        expect(audio.playbackState.value.speed, 1.5);
        expect(
          audio.playbackState.value.systemActions,
          contains(MediaAction.seek),
        );
        expect(audio.playbackState.value.controls, contains(MediaControl.play));
        final saved = await audio.audioLibrary.progressForTrack(asset.id);
        expect(saved.locator.positionMs, greaterThanOrEqualTo(4900));
        expect(saved.speed, 1.5);
        final sessions = await repository.records('session');
        expect(sessions, isNotEmpty);
        expect(sessions.first.payload!['source'], 'player');
        expect(
          sessions.first.payload!['activeSeconds'],
          inInclusiveRange(1, 4),
        );
        expect(audio.error, isEmpty);
        await audio.stop();
        await audio.open(asset, book.title);
        expect(audio.error, isEmpty);
        expect(audio.position.inMilliseconds, greaterThanOrEqualTo(4900));
        await audio.addBookmark('Проверка закладки');
        await tester.pumpWidget(
          MaterialApp(home: AudioPage(controller: audio)),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Мои закладки'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Редактировать закладку'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField),
          'Изменённая закладка',
        );
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(find.text('Изменённая закладка'), findsOneWidget);
        await tester.tap(find.byTooltip('Удалить закладку'));
        await tester.pumpAndSettle();
        expect(find.text('Изменённая закладка'), findsNothing);
        await tester.tap(find.text('Отменить удаление'));
        await tester.pumpAndSettle();
        expect(find.text('Изменённая закладка'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        final notesPreviewKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: notesPreviewKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.data(Brightness.dark),
              home: AudioPage(controller: audio),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Заметки к книге'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Добавить заметку'));
        await tester.pumpAndSettle();
        final capturedPosition = audio.position.inMilliseconds;
        await audio.seek(const Duration(seconds: 6));
        await tester.enterText(find.byType(TextFormField).at(0), 'Герой');
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Мысль к моменту',
        );
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(find.text('Мысль к моменту'), findsOneWidget);
        final note = (await audio.journal.list('audio_note')).single;
        expect(note.payload!['positionMs'], capturedPosition);
        await tester.tap(find.byTooltip('Редактировать заметку'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'Исправленная мысль',
        );
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Удалить заметку'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Отменить'));
        await tester.pumpAndSettle();
        expect(find.text('Исправленная мысль'), findsOneWidget);
        final notesImage =
            await (notesPreviewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final notesPng = await notesImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File('build/notes-preview.png')
            .writeAsBytes(notesPng!.buffer.asUint8List());
        notesImage.dispose();
        await tester.tap(find.text('К моменту'));
        await tester.pumpAndSettle();
        expect(find.byType(AudioPage), findsOneWidget);
        expect(
          audio.position.inMilliseconds,
          inInclusiveRange(capturedPosition - 250, capturedPosition + 250),
        );
        await tester.pumpWidget(const SizedBox.shrink());

        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();

        expect(
          (await audio.journal.list(
            'audio_bookmark',
            bookId: asset.bookId,
          )).length,
          1,
        );
        await audio.flushJournal();
        expect(
          (await audio.journal.list(
            'audio_event',
            bookId: asset.bookId,
            kind: 'seek',
          )).isNotEmpty,
          true,
        );
        expect(
          (await audio.journal.list(
            'audio_event',
            bookId: asset.bookId,
            kind: 'listen',
          )).isNotEmpty,
          true,
        );
        audio.setSleepTimer(0);
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(audio.playing, false);
        expect(audio.sleepMode, 'off');
        expect(
          audio.playbackState.value.processingState,
          AudioProcessingState.idle,
        );
        expect(
          (await audio.journal.list(
            'audio_event',
            bookId: asset.bookId,
            kind: 'sleep_fired',
          )).length,
          1,
        );
        expect(audio.canPlay, true);
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(audio.playing, true);
        expect(audio.position.inMilliseconds, lessThan(3000));
      } finally {
        await audio?.shutdown();
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'native queue advances, seeks across files and restores the saved track',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('pepehub-queue-');
      final db = AppDatabase(NativeDatabase.memory());
      final repository = Repository(db);
      AudioController? audio;
      try {
        final one = File('${root.path}/1.wav'),
            two = File('${root.path}/2.wav');
        await one.writeAsBytes(silentWav(seconds: 3));
        await two.writeAsBytes(silentWav(seconds: 20));
        final assets = AssetStore(
          repository,
          Directory('${root.path}/managed'),
        );
        final asset = await assets.connectAudioFolder(
          [XFile(one.path), XFile(two.path)],
          root: root.path,
          title: 'Queue',
        );
        expect(asset.path, one.path);
        expect(await assets.directory.exists(), isFalse);
        audio = await AudioController.create(assets);
        await audio.player.setVolume(0);
        await audio.open(asset, 'Queue');
        expect(audio.error, isEmpty);
        expect(audio.tracks, hasLength(2));
        await tester.pumpWidget(
          MaterialApp(home: AudioPage(controller: audio)),
        );
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('Главы (2)'),
          350,
          maxScrolls: 40,
        );
        await tester.tap(find.text('Главы (2)'));
        await tester.pumpAndSettle();
        expect(find.text('Главы книги'), findsOneWidget);
        expect(find.text('1.wav'), findsOneWidget);
        expect(find.text('2.wav'), findsOneWidget);
        expect(find.text('Встроенные главы не найдены'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await audio.scanDurations();
        expect(audio.bookDuration?.inSeconds, 23);
        expect(
          audio.trackIndex,
          0,
          reason: 'Metadata scan must not change playback',
        );
        expect(audio.position.inMilliseconds, lessThan(100));
        expect(audio.playing, isFalse);
        await audio.seekBook(const Duration(seconds: 7));
        expect(audio.trackIndex, 1);
        expect(audio.position.inMilliseconds, inInclusiveRange(3900, 4100));
        await audio.setSpeed(2);
        expect(
          audio.remainingAtSpeed?.inMilliseconds,
          inInclusiveRange(7900, 8100),
        );
        await audio.setSpeed(1);
        await audio.seekBook(Duration.zero);

        await audio.seek(const Duration(seconds: 2));
        await audio.fastForward();
        expect(audio.error, isEmpty);
        expect(audio.trackIndex, 1);
        expect(audio.position.inMilliseconds, inInclusiveRange(13900, 14100));
        await audio.rewind();
        expect(audio.trackIndex, 0);
        expect(audio.position.inMilliseconds, inInclusiveRange(1900, 2100));
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        await audio.pause();
        expect(audio.trackIndex, 1);
        expect(audio.position.inMilliseconds, greaterThan(500));
        final trackId = audio.current!.id;
        await audio.stop();
        await audio.open(asset, 'Queue');
        expect(audio.error, isEmpty);
        expect(audio.current!.id, trackId);
        expect(audio.position.inMilliseconds, greaterThan(500));
        expect(audio.bookDuration?.inSeconds, 23);
        // Commands are serialized; no stale seek may win over the last command.
        await Future.wait([
          audio.skipToQueueItem(0),
          audio.skipToQueueItem(1),
          audio.seek(const Duration(seconds: 4)),
        ]);
        expect(audio.trackIndex, 1);
        expect(audio.position.inMilliseconds, inInclusiveRange(3900, 4100));
        expect(audio.mediaItem.value?.id, trackId);
        // Fast repeated seeks must preserve transport state, including the
        // absence of transient pause events within a loaded track.
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final transport = <bool>[];
        final transportSubscription = audio.player.playingStream.listen(
          transport.add,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        transport.clear();
        await audio.skipSeconds(10);
        await audio.skipSeconds(-10);
        await Future.wait([
          audio.skipSeconds(2),
          audio.skipSeconds(2),
          audio.skipSeconds(-2),
        ]);
        expect(audio.playing, isTrue);
        expect(
          transport,
          isNot(contains(false)),
          reason: 'Seek must not pause the loaded track',
        );
        expect(audio.position.inMilliseconds, inInclusiveRange(5900, 8500));
        await transportSubscription.cancel();
        await audio.pause();
        await audio.skipSeconds(-2);
        expect(audio.playing, isFalse, reason: 'Paused seek must stay paused');
        await audio.seek(const Duration(seconds: 2));
        await audio.play();
        await audio.skipSeconds(-4);
        expect(audio.trackIndex, 0);
        expect(
          audio.playing,
          isTrue,
          reason: 'Cross-file seek resumes playback',
        );
        await audio.pause();
        await audio.skipToQueueItem(1);

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        final previewKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: previewKey,
            child: MaterialApp(
              theme: AppTheme.data(Brightness.dark),
              home: AudioPage(controller: audio),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final preview =
            await (previewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await preview.toByteData(format: ui.ImageByteFormat.png);
        await File('build/player-dark.png')
            .writeAsBytes(png!.buffer.asUint8List());
        preview.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(
          MaterialApp(
            home: AudioStatisticsPage(
              repository: repository,
              controller: audio,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('audio-mini-player')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(audio.playing, isTrue);
        await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(audio.playing, isFalse);
        final beforeOpen = audio.position;
        final openingStates = <String>[];
        final openingSubscription = audio.player.processingStateStream.listen(
          (s) => openingStates.add(s.name),
        );
        await tester.tap(find.byKey(const ValueKey('audio-mini-player')));
        await tester.pumpAndSettle();
        expect(find.byType(AudioPage), findsOneWidget);
        expect(
          audio.position.inMilliseconds,
          inInclusiveRange(
            beforeOpen.inMilliseconds - 150,
            beforeOpen.inMilliseconds + 150,
          ),
          reason: 'Opening the mini-player must not reload audio',
        );
        expect(openingStates, isNot(contains('loading')));
        await openingSubscription.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await audio.seek(const Duration(milliseconds: 19500));
        await audio.play();
        await Future<void>.delayed(const Duration(milliseconds: 1400));
        expect(audio.playing, isFalse);
        expect(audio.trackIndex, 1);
        await audio.pause();
        expect(
          (await audio.audioLibrary.progressForTrack(asset.id))
              .locator
              .positionMs,
          20000,
        );
        await audio.seek(const Duration(seconds: 4));
        await audio.stop();
        final moved = await Directory('${root.path}/moved').create();
        final movedOne = await one.rename('${moved.path}/1.wav');
        final movedTwo = await two.rename('${moved.path}/2.wav');
        await audio.open(asset, 'Queue');
        expect(audio.error, contains('Источник недоступен'));
        final restored = await assets.connectAudioFolder(
          [XFile(movedOne.path), XFile(movedTwo.path)],
          root: moved.path,
          title: 'Queue',
          replaceBookId: asset.bookId,
        );
        await audio.open(restored, 'Queue');
        expect(audio.error, isEmpty);
        expect(audio.current!.id, trackId);
        expect(audio.position.inMilliseconds, inInclusiveRange(3900, 4100));
        expect(await assets.directory.exists(), isFalse);
      } finally {
        await audio?.shutdown();
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
