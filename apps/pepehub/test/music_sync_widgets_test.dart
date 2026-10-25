import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/music/music_player_view.dart';
import 'package:pepehub/sync/peer/peer_folder_setup_page.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/sync/peer/peer_qr.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets(
    'music scrub seeks once on release rather than once per drag event',
    (tester) async {
      final seeks = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicSeekBar(
              position: 0,
              duration: 120000,
              onSeek: (value) async => seeks.add(value),
            ),
          ),
        ),
      );
      final box = tester.getRect(find.byType(Slider));
      final drag = await tester.startGesture(
        Offset(box.left + 25, box.center.dy),
      );
      await drag.moveTo(Offset(box.center.dx, box.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(box.right - 60, box.center.dy));
      await tester.pump();
      expect(seeks, isEmpty);
      await drag.up();
      await tester.pump();
      expect(seeks.length, 1);
      expect(seeks.single, inInclusiveRange(90000, 120000));
    },
  );

  testWidgets('pair QR expires visibly and removes the invitation image', (
    tester,
  ) async {
    final expires = DateTime.now().add(const Duration(minutes: 5));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerInvitationQr(code: 'pepehub-peer://pair', expires: expires),
        ),
      ),
    );
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    // The production clock is DateTime.now, so replace the widget with a known
    // expired invitation rather than assuming fake-time advances the wall clock.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerInvitationQr(
            key: const ValueKey('expired'),
            code: 'pepehub-peer://pair',
            expires: DateTime(2020),
          ),
        ),
      ),
    );
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('Код истёк'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'folder wizard previews and cancels without connecting or writing at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        final service = PeerSyncService(
          PeerStore(Repository(db)),
          observeLifecycle: false,
        );
        final root = await tester.runAsync(
          () => Directory.systemTemp.createTemp('pepehub-wizard-'),
        );
        await tester.runAsync(
          () => File('${root!.path}/song.mp3').writeAsString('123'),
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PeerFolderSetupPage(
                          service: service,
                          pick: () async => root!.path,
                        ),
                      ),
                    ),
                    child: const Text('Открыть мастер'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Открыть мастер'));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.text('Выбрать папку'));
            for (
              var tries = 0;
              tries < 100 && find.text(root!.path).evaluate().isEmpty;
              tries++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });
          await tester.pumpAndSettle();
          expect(find.text(root!.path), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('peer-folder-continue-0')),
          );
          await tester.pumpAndSettle();
          expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 1);
          await tester.ensureVisible(
            find.byKey(const ValueKey('peer-folder-continue-1')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('peer-folder-continue-1')),
          );
          await tester.pumpAndSettle();
          expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 2);
          expect(find.textContaining('1 файлов'), findsOneWidget);
          expect(service.folders, isEmpty);
          await tester.tap(find.byTooltip('Back'));
          await tester.pumpAndSettle();
          expect(find.text('Открыть мастер'), findsOneWidget);
          expect(service.folders, isEmpty);
          final names = await tester.runAsync(
            () =>
                root.list().map((file) => file.uri.pathSegments.last).toList(),
          );
          expect(names, ['song.mp3']);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          service.dispose();
          await tester.runAsync(db.close);
          // root was created in this test and is never derived from user input.
          await tester.runAsync(() => root!.delete(recursive: true));
        }
      },
    );
  }
}
