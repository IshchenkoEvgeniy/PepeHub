import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';

void main() {
  testWidgets(
    'render actual library UI using synthetic data',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes();
        await (FontLoader(
          'Roboto',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      tester.view.physicalSize = const Size(1200, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = Repository(db);
      await tester.runAsync(() async {
        await repository.addBook(
          'Путешествие к северному морю',
          'Анна Волкова',
          'epub',
        );
        await repository.addBook(
          'Искусство замечать',
          'Михаил Лесной',
          'audio',
        );
        await repository.addBook(
          'Город на краю карты',
          'Елена Соколова',
          'epub',
        );
        await repository.addSession(
          (await repository.records('book')).first,
          35,
        );
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PepeHubApp(repository: repository),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../docs/library-preview.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
    skip: Platform.environment['PEPEHUB_RENDER'] != '1',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
