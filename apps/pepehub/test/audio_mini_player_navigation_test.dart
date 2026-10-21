import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/updates/update_page.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_controller.dart';
import 'package:pepehub/media/audio_player_scope.dart';
import 'package:pepehub/ui/audio_mini_player.dart';
import 'package:pepehub/ui/pepe_widgets.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'library_folder_preference_test.dart' show section;
import 'video_player_tools_widget_test.dart' show ready;

class QueuePlayer extends ChangeNotifier implements AudioController {
  @override
  Future<void> Function()? beforeBookPlayback;
  @override
  final AssetStore assets;
  QueuePlayer(this.assets);
  @override
  LocalAsset? current = const LocalAsset(
    id: 'track',
    bookId: 'book',
    filename: 'chapter.mp3',
    path: 'unused',
    hash: 'hash',
    bytes: 1,
  );
  @override
  String get title => 'English audiobook';
  @override
  int get trackIndex => 0;
  @override
  Uri? get artwork => null;
  @override
  Duration get position => const Duration(seconds: 61);
  @override
  Duration get duration => const Duration(minutes: 10);
  @override
  double? get bookFraction => .1;
  @override
  bool get canPlay => true;
  @override
  bool playing = true;
  int pauses = 0, plays = 0;
  void clearQueue() {
    current = null;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    plays++;
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauses++;
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> flushJournal() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'custom bottom actions keep the audio bar above them without duplicate controls',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final audio = QueuePlayer(
        AssetStore(Repository(db), Directory('unused-footer')),
      );
      addTearDown(audio.dispose);
      for (final explicit in [false, true, null]) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                AudioPlayerScope(controller: audio, child: child!),
            home: PepeSubpage(
              title: 'Details',
              bottomNavigationBar: explicit == null
                  ? const AudioMiniPlayer(controller: null)
                  : explicit
                  ? AudioMiniPlayer(controller: audio)
                  : const SafeArea(
                      child: SizedBox(
                        height: 48,
                        child: Center(child: Text('Save changes')),
                      ),
                    ),
              body: const Text('Content'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('audio-mini-player')), findsOneWidget);
        if (explicit == false) {
          expect(
            tester
                .getRect(find.byKey(const ValueKey('audio-mini-player')))
                .bottom,
            lessThanOrEqualTo(tester.getRect(find.text('Save changes')).top),
          );
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    testWidgets(
      'one working audio bar on every section and settings at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = Repository(db),
            assets = AssetStore(Repository(db), Directory('unused-queue'));
        final audio = QueuePlayer(assets);
        addTearDown(audio.dispose);
        await tester.pumpWidget(
          PepeHubApp(repository: repo, audio: audio, assets: assets),
        );
        await ready(
          tester,
          () =>
              find
                  .byKey(const ValueKey('audio-mini-player'))
                  .evaluate()
                  .isNotEmpty &&
              tester
                  .widget<ShelfShell>(find.byType(ShelfShell))
                  .navigation
                  .enabled,
        );
        for (final next in PepeSection.values) {
          if (size.width < 900) {
            await section(tester, next);
          } else {
            tester
                .widget<ShelfRail>(find.byType(ShelfRail))
                .navigation
                .onSelect(next);
            await ready(
              tester,
              () =>
                  tester
                          .widget<ShelfShell>(find.byType(ShelfShell))
                          .navigation
                          .current ==
                      next &&
                  tester
                      .widget<ShelfShell>(find.byType(ShelfShell))
                      .navigation
                      .enabled &&
                  find.byType(CircularProgressIndicator).evaluate().isEmpty &&
                  find
                      .byType(LinearProgressIndicator)
                      .evaluate()
                      .every(
                        (e) =>
                            (e.widget as LinearProgressIndicator).value != null,
                      ),
            );
          }
          expect(
            find.byKey(const ValueKey('audio-mini-player')),
            findsOneWidget,
            reason: next.name,
          );
          expect(find.text('English audiobook'), findsOneWidget);
        }
        await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
        await tester.pump();
        expect(audio.pauses, 1);
        expect(audio.playing, isFalse);
        tester
            .widget<ShelfShell>(find.byType(ShelfShell))
            .navigation
            .onSettings();
        await ready(
          tester,
          () =>
              find.text('НАСТРОЙКИ').evaluate().isNotEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(find.byKey(const ValueKey('audio-mini-player')), findsOneWidget);
        if (find.text('Обновление приложения').evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text('Обновление приложения'),
            350,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await Scrollable.ensureVisible(
          tester.element(find.text('Обновление приложения')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Обновление приложения'));
        await ready(
          tester,
          () =>
              find.byType(UpdatePage).evaluate().isNotEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
        );
        expect(find.byKey(const ValueKey('audio-mini-player')), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Аккаунт'), findsNothing);
        if (find.text('Устройства и общие папки').evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text('Устройства и общие папки'),
            350,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await Scrollable.ensureVisible(
          tester.element(find.text('Устройства и общие папки')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Устройства и общие папки'));
        await tester.pumpAndSettle();
        expect(find.text('Прямой обмен между ПК и телефоном'), findsOneWidget);
        expect(find.byKey(const ValueKey('audio-mini-player')), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
        await tester.pump();
        expect(audio.plays, 1);
        expect(audio.playing, isTrue);
        expect(audio.current!.id, 'track');
        audio.clearQueue();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('audio-mini-player')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
