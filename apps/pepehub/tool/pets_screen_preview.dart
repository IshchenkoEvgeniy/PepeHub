// Dev-only preview of the whole «Питомник» screen (HUD, panels, sheets and
// the real 3D room) in a phone-sized frame, on an in-memory database.
// Not part of the app: run it on Windows to look at the layout.
//   flutter build windows --debug -t tool/pets_screen_preview.dart
// Environment:
//   PETS_SCREEN_SPECIES  fox | puppy | bunny (default fox)
//   PETS_SCREEN_LEVEL    pet level (default 6)
//   PETS_SCREEN_TAP      keys to tap one after another, e.g. dock-food,side-pets
//   PETS_SCREEN_LIGHT=1  light app theme (default: dark, like the phone)
//   PETS_PREVIEW_OUT     file.png: save the frame once the pet is shown, quit
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pets_service.dart';
import 'package:pepehub/pets/ui/pet_scene.dart';
import 'package:pepehub/pets/ui/pets_section.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/shelf_components.dart';

final _env = Platform.environment;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = Repository(AppDatabase(NativeDatabase.memory()));
  final service = PetsService(repo);
  final species = PetSpecies.values.firstWhere(
    (s) => s.name == (_env['PETS_SCREEN_SPECIES'] ?? 'fox'),
  );
  await service.enable(species: species);
  await service.devCoins(233);
  await service.devLevel(int.tryParse(_env['PETS_SCREEN_LEVEL'] ?? '') ?? 6);
  await service.markSeen(1 << 30);
  runApp(_Preview(repo));
}

class _Preview extends StatefulWidget {
  final Repository repo;
  const _Preview(this.repo);
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final shot = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_script());
  }

  /// Taps the widget under [key]: the first InkWell or GestureDetector in it.
  bool _tap(String key) {
    Element? target;
    void find(Element e) {
      if (target != null) return;
      if (e.widget.key == ValueKey(key)) {
        target = e;
        return;
      }
      e.visitChildElements(find);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(find);
    if (target == null) return false;
    VoidCallback? onTap;
    void inner(Element e) {
      if (onTap != null) return;
      final w = e.widget;
      if (w is InkWell && w.onTap != null) onTap = w.onTap;
      if (w is GestureDetector && w.onTap != null) onTap = w.onTap;
      if (onTap == null) e.visitChildElements(inner);
    }

    inner(target!);
    onTap?.call();
    return onTap != null;
  }

  Future<void> _script() async {
    for (var i = 0; i < 240 && PetRoomScene.loaded.value == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final key in (_env['PETS_SCREEN_TAP'] ?? '').split(',')) {
      if (key.trim().isEmpty) continue;
      if (!_tap(key.trim())) stderr.writeln('no tappable widget: $key');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final out = _env['PETS_PREVIEW_OUT'];
    if (out == null) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    final boundary =
        shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(out).writeAsBytes(bytes!.buffer.asUint8List());
    exit(0);
  }

  // A 390×844 phone, scaled into the window; sheets open inside it.
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF202020),
    child: FittedBox(
      child: RepaintBoundary(
        key: shot,
        child: SizedBox(
          width: 390,
          height: 844,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.data(
              Brightness.dark,
              style: _env['PETS_SCREEN_LIGHT'] == '1'
                  ? AppStyle.paper
                  : AppStyle.fallback,
            ),
            home: PetsSection(
              repository: widget.repo,
              navigation: ShelfNavigation(
                current: PepeSection.pets,
                onSelect: (_) {},
                onSettings: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
