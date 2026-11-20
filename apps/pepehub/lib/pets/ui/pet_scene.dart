import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../diagnostics/error_log.dart';
import '../../diagnostics/user_message.dart';
import '../pet_catalog.dart';
import '../pet_rules.dart';
import '../pets_service.dart';

/// Lets the home tab ask the scene for a reaction (feeding, a tap).
class PetSceneController {
  _PetHomeSceneState? _state;

  /// Eat, then a happy hop for treats or back to the mood clip.
  void eat({bool treat = false}) =>
      _state?._sequence(['Eat', if (treat) 'Happy']);
  void cheer() => _state?._sequence(['Happy']);
}

/// The bedroom with the companion. Rendered only while the home tab is
/// open (the widget is disposed with it), so reading never pays for it.
class PetHomeScene extends StatefulWidget {
  final Pet pet;
  final Set<String> owned;
  final PetSceneController? controller;
  final DateTime Function() clock;
  const PetHomeScene({
    super.key,
    required this.pet,
    required this.owned,
    this.controller,
    this.clock = DateTime.now,
  });

  @override
  State<PetHomeScene> createState() => _PetHomeSceneState();
}

/// Glb exports are Y-up: Blender (x, y, z) becomes (x, z, -y).
final _petSpot = vm.Vector3(0.35, 0.16, 0.35);

class _PetHomeSceneState extends State<PetHomeScene> {
  final scene = Scene();
  Node? room, pet;
  String? error;
  final clips = <String, AnimationClip>{};
  final ends = <String, double>{};
  final _bodies = <PhysicallyBasedMaterial>[];
  final _naturalColors = <vm.Vector4>[];
  final _accessories = <PetSocket, Node>{};
  String? _modelKey;

  final _queue = <String>[];
  String? _current, _previous;
  double _blend = 1;
  double _yaw = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PetHomeScene old) {
    super.didUpdateWidget(old);
    widget.controller?._state = this;
    if (_modelFor(widget.pet) != _modelKey) {
      unawaited(_loadPet());
    } else {
      _applyLooks();
      _settle();
    }
    _applyDecor();
  }

  static String _modelFor(Pet pet) =>
      'assets/pets/${PetSpecies.byId(pet.species)?.name ?? 'cat'}_'
      '${pet.level >= PetStage.cub.fromLevel ? 'cub' : 'baby'}.glb';

  Future<void> _load() async {
    try {
      await Scene.initializeStaticResources();
      scene.directionalLight = DirectionalLight(
        direction: vm.Vector3(-0.45, -1, -0.35),
        color: vm.Vector3(1, 0.93, 0.85),
        intensity: 2.2,
        castsShadow: true,
      );
      final loaded = await Node.fromGlbAsset('assets/pets/room_bedroom.glb');
      scene.add(loaded);
      room = loaded;
      _applyDecor();
      await _loadPet();
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets scene');
      if (mounted) setState(() => error = describeError(e));
    }
  }

  Future<void> _loadPet() async {
    final key = _modelFor(widget.pet);
    _modelKey = key;
    final node = await Node.fromGlbAsset(key);
    if (!mounted || _modelKey != key) return;
    final old = pet;
    if (old != null) scene.remove(old);
    clips.clear();
    ends.clear();
    _bodies.clear();
    _naturalColors.clear();
    _accessories.clear();
    node.position = _petSpot;
    node.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), 0.45);
    for (final animation in node.parsedAnimations) {
      final name = animation.name.split('_').last;
      clips[name] = node.createAnimationClip(animation)..weight = 0;
      ends[name] = animation.endTime;
    }
    for (final mesh in node.meshNodes) {
      for (final primitive in mesh.mesh!.primitives) {
        final material = primitive.material;
        if (material is PhysicallyBasedMaterial &&
            material.name.endsWith('_body')) {
          _bodies.add(material);
          _naturalColors.add(vm.Vector4.copy(material.baseColorFactor));
        }
      }
    }
    scene.add(node);
    setState(() => pet = node);
    _applyLooks();
    _current = null;
    _settle();
  }

  void _applyDecor() {
    final r = room;
    if (r == null) return;
    for (final item in shopItems.where((i) => i.kind == ShopKind.decor)) {
      r.getChildByName(item.decorNode)?.visible = widget.owned.contains(
        item.id,
      );
    }
  }

  Future<void> _applyLooks() async {
    final tint = shopItem(widget.pet.color ?? '')?.tint;
    for (var i = 0; i < _bodies.length; i++) {
      _bodies[i].baseColorFactor = tint == null
          ? vm.Vector4.copy(_naturalColors[i])
          : _linear(tint);
    }
    final node = pet;
    if (node == null) return;
    for (final socket in PetSocket.values) {
      final wanted = widget.pet.accessories[socket];
      final current = _accessories[socket];
      if (current != null && current.name == wanted) continue;
      if (current != null) {
        current.parent?.remove(current);
        _accessories.remove(socket);
      }
      final item = shopItem(wanted ?? '');
      final joint = node.getChildByName(
        'Socket_${socket.name[0].toUpperCase()}${socket.name.substring(1)}',
      );
      if (item?.model == null || joint == null) continue;
      final acc = await Node.fromGlbAsset(item!.model!);
      if (!mounted || pet != node) return;
      acc.name = item.id;
      joint.add(acc);
      _accessories[socket] = acc;
    }
  }

  static vm.Vector4 _linear(Color c) {
    double lin(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return vm.Vector4(lin(c.r), lin(c.g), lin(c.b), 1);
  }

  /// The clip that fits the pet's state when nothing else plays.
  String get _mood => widget.pet.satiety(widget.clock()) <= 0
      ? 'Sad'
      : (widget.clock().hour >= 23 || widget.clock().hour < 6)
      ? 'Sleep'
      : 'Idle';

  void _settle() {
    if (_queue.isEmpty && !_oneShot(_current)) _play(_mood);
  }

  static bool _oneShot(String? name) => name == 'Eat' || name == 'Happy';

  void _sequence(List<String> names) {
    _queue
      ..clear()
      ..addAll(names.where(clips.containsKey));
    _next();
  }

  void _next() {
    if (_queue.isEmpty) {
      _play(_mood);
    } else {
      _play(_queue.removeAt(0));
    }
  }

  void _play(String name) {
    final clip = clips[name];
    if (clip == null) return;
    if (name != _current) {
      _previous = _current;
      _blend = 0;
    }
    _current = name;
    clip
      ..loop = !_oneShot(name)
      ..seek(0)
      ..play();
  }

  void _tick(Duration elapsed, double dt) {
    if (_blend < 1) _blend = math.min(1, _blend + dt / 0.25);
    clips.forEach((name, clip) {
      clip.weight = name == _current
          ? _blend
          : name == _previous
          ? 1 - _blend
          : 0;
      if (clip.weight == 0 && clip.playing && name != _current) clip.stop();
    });
    final active = clips[_current];
    if (active != null &&
        _oneShot(_current) &&
        active.playbackTime >= (ends[_current] ?? 0) - 1e-3) {
      _next();
    }
  }

  Camera _camera(Duration _) {
    // The diorama camera of the Blender scene, orbiting a little on drag.
    final target = vm.Vector3(0, 0.75, 0.1);
    const distance = 8.6, height = 3.4;
    final a = 0.7 + _yaw;
    return PerspectiveCamera(
      fovRadiansY: 30 * vm.degrees2Radians,
      position:
          target +
          vm.Vector3(distance * math.sin(a), height, distance * math.cos(a)),
      target: target,
    );
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller?._state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            'Сцена не запустилась: $error',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (pet == null) return const Center(child: CircularProgressIndicator());
    return GestureDetector(
      onHorizontalDragUpdate: (d) =>
          setState(() => _yaw = (_yaw - d.delta.dx * 0.005).clamp(-0.6, 0.6)),
      onTap: () => _sequence(['Happy']),
      child: SceneView(scene, cameraBuilder: _camera, onTick: _tick),
    );
  }
}
