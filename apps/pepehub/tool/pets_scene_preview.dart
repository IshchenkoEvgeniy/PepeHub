// Dev-only preview of the pets rooms with the real 3D scene (Flutter GPU).
// Not part of the app: run it on Windows to check that the camera, the room
// render, the foreground and the pet line up.
//   flutter build windows --debug -t tool/pets_scene_preview.dart
// Cycles living → kitchen → bedroom every 6 seconds; PETS_PREVIEW_ROOM=kitchen
// pins one room, PETS_PREVIEW_SPECIES / _XP pick the model, PETS_PREVIEW_NOBG=1
// hides the room render, PETS_PREVIEW_OUT=shot.png saves a snapshot and quits.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:pepehub/pets/pets_service.dart';
import 'package:pepehub/pets/ui/pet_scene.dart';

void main() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: _Preview()),
);

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  List<PetRoom>? rooms;
  int index = 0;
  final controller = PetSceneController();
  final shot = GlobalKey();
  Timer? timer;

  /// `PETS_PREVIEW_OUT=file.png`: saves the window once the pet has loaded and quits.
  Future<void> _capture(String path) async {
    for (var i = 0; i < 240 && PetRoomScene.loaded.value == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await Future<void>.delayed(const Duration(seconds: 12));
    final boundary =
        shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
    exit(0);
  }

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final all = await PetRoom.load();
      final pinned = Platform.environment['PETS_PREVIEW_ROOM'];
      setState(
        () => rooms = pinned == null
            ? all
            : all.where((r) => r.key == pinned).toList(),
      );
      final out = Platform.environment['PETS_PREVIEW_OUT'];
      if (out != null) {
        unawaited(_capture(out));
      } else {
        timer = Timer.periodic(
          const Duration(seconds: 6),
          (_) => setState(() => index++),
        );
      }
    }());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = rooms;
    if (list == null || list.isEmpty) {
      return const ColoredBox(color: Colors.black);
    }
    final room = list[index % list.length];

    final env = Platform.environment;
    final pet = Pet(
      id: 'preview',
      species: env['PETS_PREVIEW_SPECIES'] ?? 'cat',
      name: 'Пушок',
      createdAt: DateTime(2026),
      xp: double.tryParse(env['PETS_PREVIEW_XP'] ?? '') ?? 3000,
    );
    return RepaintBoundary(
      key: shot,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: PetRoomScene(
                args: PetSceneArgs(
                  room: room,
                  pet: pet,
                  owned: const {
                    'decor_lantern',
                    'decor_book_stack',
                    'decor_globe',
                    'decor_aquarium',
                    'decor_mushroom_lamp',
                    'decor_moon_lamp',
                  },
                  asleep: false,
                  sad: false,
                  controller: controller,
                  hideRoom: env['PETS_PREVIEW_NOBG'] == '1',
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: Text(
                room.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  shadows: [Shadow(blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
