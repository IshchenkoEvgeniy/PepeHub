import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/settings_page.dart';
import 'package:pepehub/updates/update_service.dart';

import 'peer_sync_test.dart' show MemorySecrets;
import 'update_test.dart' show UpdateFixture;

void main() {
  for (final size in [
    const Size(360, 840),
    const Size(390, 900),
    const Size(1280, 900),
  ]) {
    testWidgets(
      'catalog routes, persisted settings and back navigation at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = UpdateFixture();
        late PeerSyncService peers;
        late UpdateService updates;
        await tester.runAsync(() async {
          await f.open();
          peers = PeerSyncService(
            PeerStore(f.repo),
            secrets: MemorySecrets(),
            observeLifecycle: false,
            discoverAddresses: false,
          );
          await peers.initialize();
          f.native.current = UpdateAppInfo(
            '0.24.0',
            size.width < 500 ? 2067 : 67,
            size.width < 500 ? 'android-arm64' : 'windows-x64',
          );
          updates = await f.service();
          if (size.width == 390) {
            await f.repo.setMeta(
              'audio-listening-goals',
              'invalid legacy goals',
            );
          }
        });
        final http = MockClient(
          (_) async =>
              throw StateError('No external requests in settings tests'),
        );
        final library = LibraryService(
          f.repo,
          http,
          assets: AssetStore(f.repo, f.cache),
        );
        final appearance = AppTheme(f.repo);
        final captureKey = GlobalKey();
        final output = Platform.environment['PEPEHUB_SETTINGS_SCREENSHOTS'];
        if (output != null) {
          await tester.runAsync(() async {
            for (final family in [
              'Onest',
              'Oswald',
              'Manrope',
              'CormorantGaramond',
            ]) {
              await (FontLoader(family)..addFont(
                    File('assets/fonts/$family.ttf')
                        .readAsBytes()
                        .then(ByteData.sublistView),
                  ))
                  .load();
            }
            final icons = File(
              '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            );
            await (FontLoader(
              'MaterialIcons',
            )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
          });
        }
        Future<void> capture(String name) async {
          if (output == null) return;
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1.5);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final directory = await Directory(output).create(recursive: true);
            await File(
              '${directory.path}/settings-${size.width.toInt()}-$name.png',
            ).writeAsBytes(data!.buffer.asUint8List());
          });
        }

        await tester.pumpWidget(
          PeerSyncScope(
            service: peers,
            child: UpdateScope(
              service: updates,
              child: ListenableBuilder(
                listenable: appearance,
                builder: (context, _) => ThemeScope(
                  controller: appearance,
                  child: RepaintBoundary(
                    key: captureKey,
                    child: MaterialApp(
                      debugShowCheckedModeBanner: false,
                      theme: AppTheme.data(
                        Brightness.dark,
                        style: appearance.style,
                      ),
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                          textScaler: TextScaler.linear(
                            size.width == 360 ? 1.35 : 1,
                          ),
                        ),
                        child: child!,
                      ),
                      home: SettingsPage(
                        library: library,
                        onConnection: () async {},
                        onJournal: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await capture('home');
        expect(
          find.textContaining('Не удалось прочитать настройки'),
          findsNothing,
        );
        Future<void> open(String id) async {
          final target = find.byKey(
            ValueKey('settings-${size.width >= 960 ? 'nav' : 'entry'}:$id'),
          );
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Future<void> tap(String label) async {
          await tester.ensureVisible(find.text(label));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
        }

        await open('sync');
        expect(find.text('Прямая синхронизация'), findsOneWidget);
        expect(
          find.text('Интервал автоматической синхронизации'),
          findsNothing,
        );
        await capture('sync');
        await tap('Расписание и сеть');
        await tester.ensureVisible(
          find.byKey(const ValueKey('peer-sync-interval')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('peer-sync-interval')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('3 ч').last);
        await tester.pumpAndSettle();
        expect(await f.repo.meta('peer-sync-interval'), '180');
        expect(
          peers.enabled,
          false,
        ); // Navigating never enables network access.
        await capture('rules');
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Прямая синхронизация'), findsOneWidget);
        expect(find.text('Obsidian'), findsNothing);
        await tap('Экспорт и резервные копии');
        expect(find.text('Создать резервную копию'), findsOneWidget);
        expect(find.text('Обменять с Obsidian'), findsNothing);
        expect(await f.repo.meta('peer-sync-interval'), '180');
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await open('updates');
        expect(find.text('Проверить обновления'), findsOneWidget);
        await capture('updates');
        await tap('Источник обновлений');
        expect(find.text(updates.feed), findsOneWidget);
        expect(find.byType(SelectableText), findsWidgets);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Проверить обновления'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await open('appearance');
        await tester.ensureVisible(find.byType(Slider));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Slider), const Offset(600, 0));
        await tester.pumpAndSettle();
        expect(appearance.textScale, 1.3);
        final restored = AppTheme(f.repo);
        await restored.load();
        expect(restored.textScale, 1.3);
        restored.dispose();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        appearance.dispose();
        library.dispose();
        http.close();
        updates.dispose();
        await tester.runAsync(() async {
          await peers.close();
          peers.dispose();
          await f.close();
        });
      },
    );
  }
}
