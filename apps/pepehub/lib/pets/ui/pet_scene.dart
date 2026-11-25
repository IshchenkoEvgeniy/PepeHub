import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../diagnostics/error_log.dart';
import '../../diagnostics/user_message.dart';
import '../pet_catalog.dart';
import '../pet_progress.dart';
import '../pet_rules.dart';
import '../pets_service.dart';

/// Lets the room screen ask the scene for a reaction.
class PetSceneController {
  _PetRoomSceneState? _state;

  /// Eat, then a happy hop for treats or back to the mood clip.
  void eat({bool treat = false}) =>
      _state?._sequence(['Eat', if (treat) _state!._happy]);
  void cheer() => _state?._sequence([_state!._happy]);
  void play() => _state?._sequence([
    ['Jump', 'Spin', 'Happy'][math.Random().nextInt(3)],
    'Happy',
  ]);
  void stroke() => _state?._sequence(['Pet']);
  void wave() => _state?._sequence(['Wave']);
}

/// Natural shell colors of the eggs per species.
const eggColors = {
  PetSpecies.cat: Color(0xFFD9DCE3),
  PetSpecies.fox: Color(0xFFF2B37A),
  PetSpecies.dragon: Color(0xFF9ED8CF),
};

/// A buyable decor item's home spot in a room.
class PetDecorSpot {
  final String id;
  final vm.Vector3 position;
  final double rotation, scale;
  const PetDecorSpot(this.id, this.position, this.rotation, this.scale);
}

/// One room of the pet's home, rendered in Blender (design/pets/scripts/
/// app_assets.py): a square background, an optional foreground of what
/// stands in front of the pet, the camera and the pet's spot. Positions are
/// Blender coordinates (Z up, the pet faces -Y).
class PetRoom {
  final String key, title, background;
  final String? foreground;
  final vm.Vector3 cameraPosition, cameraForward, cameraUp, spot;
  final vm.Vector3 lightDirection, lightColor;
  final double fov, yaw, lightIntensity;
  final List<PetDecorSpot> decor;
  const PetRoom({
    required this.key,
    required this.title,
    required this.background,
    required this.foreground,
    required this.cameraPosition,
    required this.cameraForward,
    required this.cameraUp,
    required this.spot,
    required this.lightDirection,
    required this.lightColor,
    required this.fov,
    required this.yaw,
    required this.lightIntensity,
    required this.decor,
  });

  static vm.Vector3 _v(Object? v) {
    final l = (v as List).map((e) => (e as num).toDouble()).toList();
    return vm.Vector3(l[0], l[1], l[2]);
  }

  /// Rooms in swipe order from `assets/pets/rooms/rooms.json` (small; read on open).
  static Future<List<PetRoom>> load() => () async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/pets/rooms/rooms.json', cache: false),
    ) as Map<String, dynamic>;
    final rooms = json['rooms'] as Map<String, dynamic>;
    return [
      for (final key in (json['order'] as List).cast<String>())
        () {
          final r = rooms[key] as Map<String, dynamic>;
          final cam = r['camera'] as Map<String, dynamic>;
          final light = r['light'] as Map<String, dynamic>;
          return PetRoom(
            key: key,
            title: r['title'] as String,
            background: r['background'] as String,
            foreground: r['foreground'] as String?,
            cameraPosition: _v(cam['position']),
            cameraForward: _v(cam['forward']),
            cameraUp: _v(cam['up']),
            fov: (cam['fov'] as num).toDouble(),
            spot: _v(r['spot']),
            yaw: (r['yaw'] as num).toDouble(),
            lightDirection: _v(light['dir']),
            lightColor: _v(light['color']),
            lightIntensity: (light['intensity'] as num).toDouble(),
            decor: [
              for (final d in (r['decor'] as List).cast<Map<String, dynamic>>())
                PetDecorSpot(
                  d['id'] as String,
                  _v(d['pos']),
                  (d['rot'] as num).toDouble(),
                  (d['scale'] as num).toDouble(),
                ),
            ],
          );
        }(),
    ];
  }();
}

/// Blender (x, y, z) in scene space: glb exports are Y-up and flutter_scene
/// mirrors imported models in Z, so a Blender point lands at (x, z, y).
vm.Vector3 blenderToScene(vm.Vector3 b) => vm.Vector3(b.x, b.z, b.y);

/// What the room screen shows in the 3D view.
class PetSceneArgs {
  final PetRoom room;
  final Pet pet;
  final Set<String> owned;
  final bool asleep, sad;
  final PetSceneController controller;
  final VoidCallback? onTapPet;

  /// Dev preview only: hides the room render to check the 3D models.
  final bool hideRoom;
  const PetSceneArgs({
    this.hideRoom = false,
    required this.room,
    required this.pet,
    required this.owned,
    required this.asleep,
    required this.sad,
    required this.controller,
    this.onTapPet,
  });
}

/// The room with the companion. Rendered only while the pets section is
/// open (the widget is disposed with it), so reading never pays for it.
class PetRoomScene extends StatefulWidget {
  /// Counts loaded pets; the dev preview waits on it before a snapshot.
  static final loaded = ValueNotifier<int>(0);
  final PetSceneArgs args;
  const PetRoomScene({super.key, required this.args});

  @override
  State<PetRoomScene> createState() => _PetRoomSceneState();
}

const _oneShots = {'Eat', 'Happy', 'Spin', 'Jump', 'Stretch', 'Wave', 'Pet'};

class _PetRoomSceneState extends State<PetRoomScene> {
  final scene = Scene();
  final _backdrop = Node(name: 'backdrop');
  final _shadow = Node(name: 'shadow');
  final _decorRoot = Node(name: 'decor');
  Node? pet, fx;
  String? error;
  final clips = <String, AnimationClip>{};
  final ends = <String, double>{};
  final _bodies = <PhysicallyBasedMaterial>[];
  final _naturalColors = <vm.Vector4>[];
  final _accessories = <PetSocket, Node>{};
  final _textures = <String, Texture2D>{};
  final _decorModels = <String, Node>{};
  String? _modelKey, _roomKey;
  double _aspect = 9 / 16;

  final _queue = <String>[];
  String? _current, _previous;
  double _blend = 1;
  double _time = 0, _idleSince = 0;

  PetSceneArgs get a => widget.args;

  @override
  void initState() {
    super.initState();
    a.controller._state = this;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PetRoomScene old) {
    super.didUpdateWidget(old);
    a.controller._state = this;
    if (_modelFor(a.pet) != _modelKey) {
      unawaited(_loadPet());
    } else {
      unawaited(_applyLooks());
      _settle();
    }
    if (a.room.key != _roomKey || old.args.owned.length != a.owned.length) {
      unawaited(_applyRoom());
    }
  }

  static String _modelFor(Pet pet) =>
      PetGrowth.modelAsset(pet.species, pet.level, pet.path);

  bool _has(TalentEffect effect) => a.pet.has(effect);
  String get _happy => _has(TalentEffect.jump) ? 'Jump' : 'Happy';

  Future<void> _load() async {
    try {
      await Scene.initializeStaticResources();
      // The rooms are pre-lit renders: show their pixels unchanged.
      scene
        ..toneMapping = ToneMappingMode.linear
        ..exposure = 1
        ..environmentIntensity = 0.75;
      scene
        ..add(_backdrop)
        ..add(_decorRoot)
        ..add(_shadow);
      await _applyRoom();
      await _loadPet();
      _sequence(['Wave']);
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets scene');
      if (mounted) setState(() => error = describeError(e));
    }
  }

  /// Room renders are shown about 1:1, so no mip chain (building one on the
  /// CPU for a 2048² image takes very long); an opaque render wraps the
  /// decoded GPU image directly.
  Future<Texture2D> _texture(String asset, {bool opaque = false}) async {
    final cached = _textures[asset];
    if (cached != null) return cached;
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final image = (await codec.getNextFrame()).image;
    try {
      return _textures[asset] = await Texture2D.fromImage(
        image,
        opaque: opaque,
        sampling: const TextureSampling(mipmaps: false),
      );
    } finally {
      image.dispose();
    }
  }

  /// A camera-facing quad covering the view at [distance] from the camera.
  Future<Node> _screenQuad(Node node, String asset, double distance) async {
    final room = a.room;
    final p = blenderToScene(room.cameraPosition);
    final f = blenderToScene(room.cameraForward).normalized();
    final up0 = blenderToScene(room.cameraUp).normalized();
    final r = up0
        .cross(f)
        .normalized(); // the camera's right, as flutter_scene computes it
    final u = f.cross(r).normalized();
    final h = distance * math.tan(room.fov / 2) * 1.02;
    final c = p + f * distance;
    final corners = [
      c - r * h + u * h,
      c + r * h + u * h,
      c - r * h - u * h,
      c + r * h - u * h,
    ];
    final positions = Float32List(12);
    for (var i = 0; i < 4; i++) {
      positions[i * 3] = corners[i].x;
      positions[i * 3 + 1] = corners[i].y;
      positions[i * 3 + 2] = corners[i].z;
    }
    final n = -f;
    final geometry = MeshGeometry.fromArrays(
      positions: positions,
      normals: Float32List.fromList([
        for (var i = 0; i < 4; i++) ...[n.x, n.y, n.z],
      ]),
      texCoords: Float32List.fromList([0, 0, 1, 0, 0, 1, 1, 1]),
      indices: [0, 2, 1, 1, 2, 3],
    );
    final material =
        UnlitMaterial(colorTexture: await _texture(asset, opaque: true))
          ..doubleSided = true
          ..vertexColorWeight = 0;
    node.mesh = Mesh(geometry, material);
    return node;
  }

  Future<void> _applyRoom() async {
    final room = a.room;
    _roomKey = room.key;
    await _screenQuad(_backdrop, room.background, 30);
    _backdrop.visible = !a.hideRoom;
    // Soft round shadow under the pet.
    final s = blenderToScene(room.spot);
    const half = 0.42;
    final y = s.y + 0.004;
    final shadowMaterial =
        UnlitMaterial(
            colorTexture: await _texture('assets/pets/rooms/shadow.png'),
          )
          ..alphaMode = AlphaMode.blend
          ..doubleSided = true
          ..vertexColorWeight = 0;
    _shadow.mesh = Mesh(
      MeshGeometry.fromArrays(
        positions: Float32List.fromList([
          s.x - half,
          y,
          s.z - half,
          s.x + half,
          y,
          s.z - half,
          s.x - half,
          y,
          s.z + half,
          s.x + half,
          y,
          s.z + half,
        ]),
        normals: Float32List.fromList([
          for (var i = 0; i < 4; i++) ...[0, 1, 0],
        ]),
        texCoords: Float32List.fromList([0, 0, 1, 0, 0, 1, 1, 1]),
        indices: [0, 2, 1, 1, 2, 3],
      ),
      shadowMaterial,
    );
    final d = blenderToScene(room.lightDirection).normalized();
    scene.directionalLight = DirectionalLight(
      direction: d,
      color: room.lightColor,
      intensity: room.lightIntensity,
      castsShadow: false,
    );
    // Decor bought for this room.
    for (final child in [..._decorRoot.children]) {
      _decorRoot.remove(child);
    }
    for (final spot in room.decor) {
      if (!a.owned.contains(spot.id)) continue;
      final item = shopItem(spot.id);
      if (item == null) continue;
      try {
        final model = _decorModels[spot.id] ??= await Node.fromGlbAsset(
          item.decorModel,
        );
        if (!mounted || _roomKey != room.key) return;
        final holder = Node(name: 'decor:${spot.id}')..add(model);
        holder.position = blenderToScene(spot.position);
        holder.rotation = vm.Quaternion.axisAngle(
          vm.Vector3(0, 1, 0),
          -spot.rotation * vm.degrees2Radians,
        );
        holder.scale = vm.Vector3.all(spot.scale);
        _decorRoot.add(holder);
      } catch (e, stack) {
        ErrorLog.record(e, stack, context: 'pets decor ${spot.id}');
      }
    }
    _placePet();
    if (mounted) setState(() {});
  }

  Future<void> _loadPet() async {
    final key = _modelFor(a.pet);
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
    PetRoomScene.loaded.value++;
  }

  void _placePet() {
    final node = pet;
    if (node == null) return;
    node.position = blenderToScene(a.room.spot);
    node.rotation = vm.Quaternion.axisAngle(
      vm.Vector3(0, 1, 0),
      a.room.yaw * vm.degrees2Radians,
    );
    node.scale = vm.Vector3.all(PetGrowth.stageScale(a.pet.level));
  }

  Future<void> _applyLooks() async {
    final p = a.pet;
    final tint = shopItem(p.color ?? '')?.tint;
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
        ..metallicFactor = p.rank >= 1 ? 0.25 : 0
        ..roughnessFactor = p.rank >= 1 ? 0.4 : 0.75;
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
    final p = a.pet;
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

  static vm.Vector4 _linear(Color c) {
    double lin(double v) => v <= 0.04045
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return vm.Vector4(lin(c.r), lin(c.g), lin(c.b), 1);
  }

  /// The clip that fits the pet's state when nothing else plays.
  String get _mood {
    if (a.asleep && !_has(TalentEffect.nightOwl)) return 'Sleep';
    if (a.sad) return 'Sad';
    return 'Idle';
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
  }

  Camera _camera(Duration _) {
    final room = a.room;
    final p = blenderToScene(room.cameraPosition);
    final f = blenderToScene(room.cameraForward);
    // The render is square: keep the view inside it for any window shape.
    final fov = _aspect > 1
        ? 2 * math.atan(math.tan(room.fov / 2) / _aspect)
        : room.fov;
    return PerspectiveCamera(
      fovRadiansY: fov,
      position: p,
      target: p + f,
      up: blenderToScene(room.cameraUp),
    );
  }

  @override
  void dispose() {
    if (a.controller._state == this) a.controller._state = null;
    super.dispose();
  }

  /// A square room render placed exactly like the backdrop quad: the camera
  /// fits the square by height in a tall view and by width in a wide one,
  /// and the quad overshoots the view by 2 %.
  Widget _roomLayer(String asset, BoxConstraints constraints) {
    final side = 1.02 * math.max(constraints.maxWidth, constraints.maxHeight);
    return ClipRect(
      child: OverflowBox(
        minWidth: side,
        maxWidth: side,
        minHeight: side,
        maxHeight: side,
        child: Image.asset(
          asset,
          width: side,
          height: side,
          fit: BoxFit.fill,
          gaplessPlayback: true,
        ),
      ),
    );
  }

  /// A note over the room render, above the panels at the bottom of the
  /// screen (they would hide one in the middle).
  Widget _note(Widget child) => Align(
    alignment: const Alignment(0, -.25),
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF4E8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE7D9C3), width: 1.5),
      ),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _aspect = constraints.maxWidth / math.max(1, constraints.maxHeight);
        final fg = a.hideRoom ? null : a.room.foreground;
        if (pet == null || error != null) {
          return Stack(
            fit: StackFit.expand,
            children: [
              _roomLayer(a.room.background, constraints),
              if (fg != null) _roomLayer(fg, constraints),
              if (error != null)
                _note(
                  SelectableText(
                    'Питомец не загрузился: $error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF3E2F4A)),
                  ),
                )
              else
                _note(
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Color(0xFF8E76C2),
                    ),
                  ),
                ),
            ],
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: a.onTapPet,
              child: SceneView(scene, cameraBuilder: _camera, onTick: _tick),
            ),
            // What stands in front of the pet (the kitchen table, the bed's
            // rim) is a flat layer over the 3D view: it is always in front.
            if (fg != null) IgnorePointer(child: _roomLayer(fg, constraints)),
          ],
        );
      },
    );
  }
}
