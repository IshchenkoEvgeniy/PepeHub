import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/updates/update_page.dart';
import 'package:pepehub/updates/update_service.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'update_test.dart' show UpdateFixture;
import 'video_player_tools_widget_test.dart' show ready;

void main() {
  testWidgets(
    'phone update screen fits large text and installs the downloaded APK after permission',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = UpdateFixture();
      await tester.runAsync(f.open);
      f.native.current = const UpdateAppInfo('0.21.0', 2051, 'android-arm64');
      f.native.status = 'permissionRequired';
      late UpdateService service;
      await tester.runAsync(() async {
        service = await f.service();
        await service.check();
      });
      addTearDown(() async {
        service.dispose();
        await f.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: UpdatePage(service: service),
        ),
      );
      Future<void> tap(String text) async {
        if (find.text(text).evaluate().isEmpty) {
          await tester.scrollUntilVisible(find.text(text), 250);
        }
        await Scrollable.ensureVisible(
          tester.element(find.text(text)),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pump();
      }

      await tap('Скачать обновление');
      await ready(tester, () => service.phase == UpdatePhase.ready);
      await tap('Установить обновление');
      await ready(
        tester,
        () => service.phase == UpdatePhase.permissionRequired,
      );
      expect(find.text('Разрешить установку'), findsOneWidget);
      expect(f.native.installs, 1);
      f.native.status = 'installerOpened';
      f.native.permissionGranted = true;
      await tap('Разрешить установку');
      await ready(tester, () => service.phase == UpdatePhase.installerOpened);
      expect(f.native.installs, 2);
      expect(f.native.settings, 2);
      expect(f.native.exits, 0);
      await tap('Скачать APK через браузер');
      await ready(tester, () => f.native.openedDownload != null);
      expect(f.native.openedDownload, service.artifact!.url);
      expect(tester.takeException(), isNull);
    },
  );
}
