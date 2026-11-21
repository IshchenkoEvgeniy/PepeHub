import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../diagnostics/error_log.dart';
import '../../diagnostics/user_message.dart';
import '../pet_catalog.dart';
import '../pet_progress.dart';
import '../pet_rules.dart';
import '../pets_service.dart';

/// Lets the home tab ask the scene for a reaction (feeding, a tap).
class PetSceneController {
  _PetHomeSceneState? _state;

  /// Eat, then a happy hop for treats or back to the mood clip.
  void eat({bool treat = false}) =>
      _state?._sequence(['Eat', if (treat) _state!._happy]);
  void cheer() => _state?._sequence([_state!._happy]);
}

/// Natural shell colors of the eggs per species.
const eggColors = {
  PetSpecies.cat: Color(0xFFD9DCE3),
  PetSpecies.fox: Color(0xFFF2B37A),
  PetSpecies.dragon: Color(0xFF9ED8CF),
};

/// The bedroom with the companion and the eggs of the incubator. Rendered
/// only while the home tab is open (the widget is disposed with it), so
/// reading never pays for it.
class PetHomeScene extends StatefulWidget {
  final Pet pet;
  final Set<String> owned;
  final List<PetEgg> eggs;
  final PetSceneController? controller;
  final DateTime Function() clock;
  const PetHomeScene({
    super.key,
    required this.pet,
    required this.owned,
    this.eggs = const [],
    this.controller,
    this.clock = DateTime.now,
  });

  @override
  State<PetHomeScene> createState() => _PetHomeSceneState();
}

/// Glb exports are Y-up, (x, z, -y) of Blender, and flutter_scene mirrors
/// imported models in Z: in the scene Blender (x, y, z) lands at (x, z, y).
/// Models sit under holder nodes, so moving them keeps the import mirror.
final _poufSpot = vm.Vector3(0.35, 0.16, -0.35);
final _bedSpot = vm.Vector3(-0.55, 0.59, 0.7);
final _eggSpots = [vm.Vector3(1.0, 0.01, -0.75), vm.Vector3(-0.2, 0.01, -0.95)];

const _oneShots = {'Eat', 'Happy', 'Spin', 'Jump', 'Stretch'};

class _PetHomeSceneState extends State<PetHomeScene> {
  final scene = Scene();
  Node? room, pet, fx;
  String? error;
  final clips = <String, AnimationClip>{};
  final ends = <String, double>{};
  final _bodies = <PhysicallyBasedMaterial>[];
  final _naturalColors = <vm.Vector4>[];
  final _accessories = <PetSocket, Node>{};
  final _eggs = <Node>[];
  String? _modelKey;

  final _queue = <String>[];
  String? _current, _previous;
  double _blend = 1;
  double _yaw = 0;
  double _time = 0, _idleSince = 0;

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
      _placePet();
      unawaited(_applyLooks());
      _settle();
    }
    _applyDecor();
    unawaited(_applyEggs());
  }

  static String _modelFor(Pet pet) =>
      PetGrowth.modelAsset(pet.species, pet.level, pet.path);

  bool _has(TalentEffect effect) => widget.pet.has(effect);
  String get _happy => _has(TalentEffect.jump) ? 'Jump' : 'Happy';

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
      await _applyEggs();
      if (_has(TalentEffect.greet)) _sequence([_happy]);
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets scene');
      if (mounted) setState(() => error = describeError(e));
    }
  }

  Future<void> _loadPet() async {
    final key = _modelFor(widget.pet);
    _modelKey = key;
    final model = await Node.fromGlbAsset(key);
    final node = Node(name: 'pet')..add(model);
    if (!mounted || _modelKey != key) return;
    final old = pet;
    if (old != null) scene.remove(old);
    clips.clear();
    ends.clear();
    _bodies.clear();
    _naturalColors.clear();
    _accessories.clear();
    fx = null;
    for (final animation in model.parsedAnimations) {
      final name = animation.name.split('_').last;
      clips[name] = model.createAnimationClip(animation)..weight = 0;
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
    _placePet();
    await _applyLooks();
    _current = null;
    _settle();
  }

  void _placePet() {
    final node = pet;
    if (node == null) return;
    final bed = _has(TalentEffect.bedSpot);
    node.position = bed ? _bedSpot : _poufSpot;
    node.rotation = vm.Quaternion.axisAngle(
      vm.Vector3(0, 1, 0),
      bed ? -0.3 : -0.6,
    );
    final s = PetGrowth.stageScale(widget.pet.level);
    node.scale = vm.Vector3.all(s);
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
    final p = widget.pet;
    final tint = shopItem(p.color ?? '')?.tint;
    // Elders go a little grey.
    final grey = p.stage.index >= PetStage.elder.index ? 0.3 : 0.0;
    for (var i = 0; i < _bodies.length; i++) {
      final base = tint == null
          ? vm.Vector4.copy(_naturalColors[i])
          : _linear(tint);
      final g = (base.x + base.y + base.z) / 3 * 0.6 + 0.35;
      _bodies[i]
        ..baseColorFactor = vm.Vector4(
          base.x + (g - base.x) * grey,
          base.y + (g - base.y) * grey,
          base.z + (g - base.z) * grey,
          1,
        )
        // ★ adds a shine.
        ..metallicFactor = p.rank >= 1 ? 0.35 : 0
        ..roughnessFactor = p.rank >= 1 ? 0.35 : 0.8;
    }
    final node = pet;
    if (node == null) return;
    await _applyFx(node);
    for (final socket in PetSocket.values) {
      final wanted = p.accessories[socket];
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

  /// ★★ particles circle the pet, ★★★ and level 100 add the aura ring.
  Future<void> _applyFx(Node node) async {
    final p = widget.pet;
    final particles = p.rank >= 2;
    final aura = p.rank >= 3 || p.level >= PetRules.maxLevel;
    if (!particles && !aura) {
      fx?.visible = false;
      return;
    }
    var effects = fx;
    if (effects == null) {
      effects = await Node.fromGlbAsset('assets/pets/fx_rank.glb');
      if (!mounted || pet != node) return;
      node.add(effects);
      fx = effects;
    }
    effects.visible = true;
    effects.getChildByName('Fx_Particles')?.visible = particles;
    effects.getChildByName('Fx_Aura')?.visible = aura;
  }

  Future<void> _applyEggs() async {
    final r = room;
    if (r == null) return;
    final wanted = widget.eggs.take(_eggSpots.length).toList();
    while (_eggs.length < wanted.length) {
      final node = Node(name: 'egg')
        ..add(await Node.fromGlbAsset('assets/pets/egg.glb'));
      if (!mounted) return;
      if (_eggs.length >= widget.eggs.take(_eggSpots.length).length) break;
      node.position = _eggSpots[_eggs.length];
      scene.add(node);
      _eggs.add(node);
    }
    while (_eggs.length > wanted.length) {
      scene.remove(_eggs.removeLast());
    }
    for (var i = 0; i < _eggs.length && i < wanted.length; i++) {
      final egg = wanted[i], node = _eggs[i];
      for (var c = 1; c <= 3; c++) {
        node.getChildByName('Crack_$c')?.visible = egg.fraction >= c / 4;
      }
      final color = eggColors[PetSpecies.byId(egg.species)];
      for (final mesh in node.meshNodes) {
        for (final primitive in mesh.mesh!.primitives) {
          final m = primitive.material;
          if (m is PhysicallyBasedMaterial &&
              m.name == 'Egg_shell' &&
              color != null) {
            m.baseColorFactor = _linear(color);
          }
        }
      }
    }
  }

  static vm.Vector4 _linear(Color c) {
    double lin(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return vm.Vector4(lin(c.r), lin(c.g), lin(c.b), 1);
  }

  /// The clip that fits the pet's state when nothing else plays.
  String get _mood {
    final now = widget.clock();
    if (widget.pet.satiety(now) <= 0) return 'Sad';
    final night = now.hour >= 23 || now.hour < 6;
    return night && !_has(TalentEffect.nightOwl) ? 'Sleep' : 'Idle';
  }

  void _settle() {
    if (_queue.isEmpty && !_oneShots.contains(_current)) _play(_mood);
  }

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
      if (name == 'Idle') _idleSince = _time;
    }
    _current = name;
    clip
      ..loop = !_oneShots.contains(name)
      ..seek(0)
      ..play();
  }

  void _tick(Duration elapsed, double dt) {
    _time += dt;
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
        _oneShots.contains(_current) &&
        active.playbackTime >= (ends[_current] ?? 0) - 1e-3) {
      _next();
    }
    // A long idle ends with a stretch now and then.
    if (_current == 'Idle' &&
        _has(TalentEffect.stretch) &&
        _time - _idleSince > 18) {
      _sequence(['Stretch']);
    }
    fx?.getChildByName('Fx_Particles')?.rotation = vm.Quaternion.axisAngle(
      vm.Vector3(0, 1, 0),
      _time * 0.8,
    );
    fx?.getChildByName('Fx_Aura')?.rotation = vm.Quaternion.axisAngle(
      vm.Vector3(0, 1, 0),
      -_time * 0.3,
    );
    // Ready eggs wobble.
    for (var i = 0; i < _eggs.length && i < widget.eggs.length; i++) {
      _eggs[i].rotation = widget.eggs[i].ready
          ? vm.Quaternion.axisAngle(
              vm.Vector3(0, 0, 1),
              math.sin(_time * 9) *
                  0.12 *
                  (math.sin(_time * 1.3) > 0.3 ? 1 : 0),
            )
          : vm.Quaternion.identity();
    }
  }

  Camera _camera(Duration _) {
    // The diorama camera of the Blender scene, orbiting a little on drag.
    final target = vm.Vector3(0, 0.75, -0.1);
    const distance = 8.6, height = 3.4;
    final a = 0.7 + _yaw;
    return PerspectiveCamera(
      fovRadiansY: 30 * vm.degrees2Radians,
      position:
          target +
          vm.Vector3(distance * math.sin(a), height, -distance * math.cos(a)),
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
      onTap: () => _sequence([_has(TalentEffect.spin) ? 'Spin' : _happy]),
      child: SceneView(scene, cameraBuilder: _camera, onTick: _tick),
    );
  }
}
