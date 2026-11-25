import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../data/repository.dart';
import '../../diagnostics/error_log.dart';
import '../../diagnostics/user_message.dart';
import '../../ui/shelf_components.dart';
import '../pet_catalog.dart';
import '../pet_progress.dart';
import '../pet_rules.dart';
import '../pets_service.dart';
import 'pet_scene.dart';

part 'pets_tabs.dart';
part 'pets_windows.dart';
part 'pets_dev_panel.dart';

/// Builds the 3D room; tests replace it (Flutter GPU is not available there).
typedef PetSceneBuilder = Widget Function(BuildContext context, PetSceneArgs args);

Widget _defaultScene(BuildContext context, PetSceneArgs args) => PetRoomScene(args: args);

/// Colors of the pets screen (cozy cream panels, lavender accent), the same
/// in light and dark app themes: the panels float over a rendered room.
abstract final class PetsLook {
  static const cream = Color(0xFFFBF4E8);
  static const card = Color(0xFFFFFDF8);
  static const line = Color(0xFFE7D9C3);
  static const lavender = Color(0xFF8E76C2);
  static const lavenderSoft = Color(0xFFF1E8F8);
  static const deep = Color(0xFF5E4A8E);
  static const ink = Color(0xFF3E2F4A);
  static const muted = Color(0xFF7A6A86);
  static const gold = Color(0xFFE9B949);
  static const food = Color(0xFFE9A24E);
  static const sleep = Color(0xFF7A8BD6);
  static const joy = Color(0xFF7FB37A);

  static TextStyle title([double size = 20]) => TextStyle(
    fontFamily: 'ReaderLora',
    fontWeight: FontWeight.w700,
    fontSize: size,
    color: ink,
  );

  static BoxDecoration panel({double radius = 24, double alpha = .97}) => BoxDecoration(
    color: cream.withValues(alpha: alpha),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: line, width: 1.5),
    boxShadow: const [BoxShadow(color: Color(0x40281A28), blurRadius: 18, offset: Offset(0, 6))],
  );

  /// Theme for sheets and dialogs over the room.
  static ThemeData theme(BuildContext context) {
    final base = Theme.of(context);
    final scheme = ColorScheme.fromSeed(seedColor: lavender, brightness: Brightness.light)
        .copyWith(primary: lavender, surface: cream, onSurface: ink);
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: cream,
      cardTheme: base.cardTheme.copyWith(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: line, width: 1.2),
        ),
      ),
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: const IconThemeData(color: deep),
      dividerColor: line,
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: card,
        selectedColor: lavenderSoft,
        side: const BorderSide(color: line),
        labelStyle: const TextStyle(color: ink),
      ),
      extensions: base.extensions.values,
    );
  }
}

/// The «Питомник» section: the pet's home with three rooms, the shop and the
/// windows of the concept. Recounts reading when opened and when the app
/// returns to the front.
class PetsSection extends StatefulWidget {
  final Repository repository;
  final ShelfNavigation navigation;
  final PetSceneBuilder sceneBuilder;
  final DateTime Function()? clock;
  const PetsSection({
    super.key,
    required this.repository,
    required this.navigation,
    this.sceneBuilder = _defaultScene,
    this.clock,
  });

  @override
  State<PetsSection> createState() => _PetsSectionState();
}

class _PetsSectionState extends State<PetsSection> with WidgetsBindingObserver {
  /// Developer clock shift (minutes); applied on top of the real clock.
  int _shift = 0;
  late final service = PetsService(
    widget.repository,
    clock: () => (widget.clock ?? DateTime.now)().add(Duration(minutes: _shift)),
  );
  final scene = PetSceneController();
  final overview = ValueNotifier<PetsOverview?>(null);
  List<PetRoom>? rooms;
  int room = 0;
  String? error;
  bool busy = false, dev = false, _rewardShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      dev = kDebugMode || await service.devEnabled();
      _shift = await service.devClockShift();
      rooms = await PetRoom.load();
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets rooms');
    }
    await _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    overview.dispose();
    super.dispose();
  }

  DateTime get now => service.clock();

  Future<void> _refresh() async {
    try {
      await service.sync();
      final next = await service.overview();
      if (!mounted) return;
      overview.value = next;
      setState(() => error = null);
      _maybeReward(next);
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets section');
      if (mounted) setState(() => error = describeError(e));
    }
  }

  /// Runs a user action; a refused one is explained, not logged as a crash.
  Future<T?> _act<T>(Future<T> Function() action) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      final result = await action();
      await _refresh();
      return result;
    } on PetsActionError catch (e) {
      _say(e.message);
    } catch (e, stack) {
      ErrorLog.record(e, stack, context: 'pets action');
      _say('Не получилось: ${describeError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    return null;
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _maybeReward(PetsOverview o) {
    if (_rewardShown || o.enabledAt == null || o.companion == null || o.unseen.isEmpty) return;
    _rewardShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showRewardDialog(context, o);
      await service.markSeen(o.unseen.lastId);
      scene.cheer();
      _rewardShown = false;
      await _refresh();
    });
  }

  void setRoom(int index) => setState(() => room = index);

  Future<void> setShift(int minutes) async {
    _shift = minutes;
    await service.setDevClockShift(minutes);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => ShelfShell(
    title: 'Питомник',
    navigation: widget.navigation,
    header: false,
    body: ValueListenableBuilder<PetsOverview?>(
      valueListenable: overview,
      builder: (context, o, _) => _body(o),
    ),
  );

  Widget _body(PetsOverview? o) {
    if (o == null || rooms == null) {
      return error == null
          ? const Center(child: CircularProgressIndicator())
          : Center(child: SelectableText('Питомник не открылся: $error'));
    }
    if (o.enabledAt == null || o.companion == null) {
      return _StarterPicker(
        busy: busy,
        onPick: (species) => _act(() => service.enable(species: species)),
      );
    }
    return _Home(state: this, o: o, rooms: rooms!);
  }
}

// ---------------------------------------------------------------- home

/// One room on the whole screen with the HUD, the side buttons, the room's
/// own panel and the dock.
class _Home extends StatefulWidget {
  final _PetsSectionState state;
  final PetsOverview o;
  final List<PetRoom> rooms;
  const _Home({required this.state, required this.o, required this.rooms});
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool decorating = false;
  _PetsSectionState get s => widget.state;
  PetsOverview get o => widget.o;
  PetRoom get room => widget.rooms[s.room % widget.rooms.length];
  Pet get pet => o.companion!;

  void _go(int delta) {
    s.setRoom((s.room + delta) % widget.rooms.length);
    setState(() => decorating = false);
  }

  void finishDecorating() => setState(() => decorating = false);

  void _goTo(String key) {
    final i = widget.rooms.indexWhere((r) => r.key == key);
    if (i >= 0) s.setRoom(i);
  }

  double get satiety => pet.satiety(s.now);
  double get energy => PetRules.energy(s.now, lightsOff: o.lightsOff, lightsUntil: o.lightsUntil);
  bool get asleep => PetRules.asleep(s.now, lightsOff: o.lightsOff, lightsUntil: o.lightsUntil);
  double get mood => o.moodOf(pet);

  @override
  Widget build(BuildContext context) {
    final args = PetSceneArgs(
      room: room,
      pet: pet,
      owned: o.owned,
      asleep: asleep,
      sad: satiety <= 0 || mood < 0.12,
      controller: s.scene,
      onTapPet: () {
        if (decorating) return;
        s.scene.stroke();
        unawaited(s.service.stroke(pet.id));
      },
    );
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 520;
        return GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v.abs() > 250) _go(v < 0 ? 1 : -1);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              s.widget.sceneBuilder(context, args),
              const IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    height: 150,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66201420), Color(0x00201420)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (decorating)
                _DecorateLayer(home: this, size: c.biggest)
              else ...[
                Positioned(left: 12, top: 12, right: 70, child: _hud(narrow)),
                Positioned(right: 12, top: 12, child: _sideButtons()),
                if (room.key == 'living' && !asleep)
                  Positioned(
                    right: narrow ? 14 : c.maxWidth * .18,
                    top: c.maxHeight * .3,
                    child: _bubble(),
                  ),
                Positioned(left: 10, right: 10, bottom: 10, child: _bottom(narrow)),
              ],
            ],
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------- HUD

  Widget _hud(bool narrow) {
    final start = PetRules.totalXpForLevel(pet.level);
    final need = PetRules.xpForLevel(pet.level);
    final max = pet.level >= PetRules.maxLevel;
    final progress = max ? 1.0 : ((pet.xp - start) / need).clamp(0.0, 1.0);
    final status = switch (room.key) {
      'kitchen' => _bar('Сытость', satiety <= 0 ? 'голоден' : '${(satiety * 100).round()}%', satiety, PetsLook.food),
      'bedroom' => _bar('Бодрость', '${(energy * 100).round()}%${asleep ? ' · спит' : ''}', energy, PetsLook.sleep),
      _ => _bar(
          o.bookOfDay == null ? 'Сегодня засчитано' : 'Книга дня: ${o.bookOfDay}',
          '${_hm(o.todayCredited)} / ${_hm(PetRules.dailyMinutes)}',
          o.todayCredited / PetRules.dailyMinutes,
          PetsLook.lavender,
        ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            GestureDetector(
              onTap: () => _showPetsWindow(context, s, _PetsWindowKind.pets),
              child: _LevelRing(level: pet.level, progress: progress),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 90),
              child: Text(
                pet.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  shadows: [Shadow(color: Color(0x99000000), blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Pill(
                    key: const ValueKey('pets-balance'),
                    icon: const _Coin(size: 20),
                    text: '${o.balance}',
                    onTap: () => _showShop(context, s),
                  ),
                  _Pill(
                    icon: const Icon(Icons.local_fire_department_rounded, color: Color(0xFFE58A4E), size: 20),
                    text: '${o.streak.current} дн.',
                  ),
                  if (s.dev)
                    _Pill(
                      key: const ValueKey('pets-dev'),
                      icon: const Icon(Icons.build_circle_outlined, color: PetsLook.deep, size: 20),
                      text: 'DEV',
                      onTap: () => _showDevPanel(context, s),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: status),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bar(String title, String value, double v, Color color) => Container(
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
    decoration: PetsLook.panel(radius: 14, alpha: .93),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: PetsLook.ink)),
            ),
            Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: v.clamp(0.0, 1.0),
            minHeight: 6,
            color: color,
            backgroundColor: const Color(0xFFE6DCEB),
          ),
        ),
      ],
    ),
  );

  Widget _sideButtons() {
    final pending = o.pets.any((p) => p.pathPending) || o.eggs.any((e) => e.ready);
    return Column(
      children: [
        _RoundButton(
          key: const ValueKey('side-pets'),
          icon: Icons.pets_rounded,
          tooltip: 'Питомцы и инкубатор',
          dot: pending,
          onTap: () => _showPetsWindow(context, s, _PetsWindowKind.pets),
        ),
        const SizedBox(height: 10),
        _RoundButton(
          key: const ValueKey('side-decorate'),
          icon: Icons.format_paint_outlined,
          tooltip: 'Ремонт',
          onTap: () => setState(() => decorating = true),
        ),
        const SizedBox(height: 10),
        _RoundButton(
          key: const ValueKey('side-achievements'),
          icon: Icons.emoji_events_outlined,
          tooltip: 'Достижения',
          onTap: () => _showPetsWindow(context, s, _PetsWindowKind.achievements),
        ),
        const SizedBox(height: 10),
        _RoundButton(
          key: const ValueKey('side-journal'),
          icon: Icons.photo_album_outlined,
          tooltip: 'Альбом и журнал',
          onTap: () => _showPetsWindow(context, s, _PetsWindowKind.album),
        ),
      ],
    );
  }

  Widget _bubble() => GestureDetector(
    onTap: () => _showReadingSheet(context, s),
    child: Container(
      width: 170,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: PetsLook.panel(radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            satiety <= 0
                ? 'Я проголодался… Заглянем на кухню?'
                : o.todayCredited >= PetRules.dailyMinutes
                ? 'Сегодня мы отлично почитали!'
                : 'Почитаем вместе?',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: PetsLook.ink, height: 1.25),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(color: PetsLook.lavender, borderRadius: BorderRadius.circular(12)),
            child: Text(
              satiety <= 0 ? 'На кухню' : 'Книга или аудио',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    ),
  );

  // -------------------------------------------------------------- bottom

  Widget _bottom(bool narrow) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (room.key == 'kitchen') ...[_FoodTray(home: this), const SizedBox(height: 10)],
      if (room.key == 'bedroom') ...[_NightPanel(home: this), const SizedBox(height: 10)],
      _roomSwitcher(),
      const SizedBox(height: 10),
      _dock(),
    ],
  );

  Widget _roomSwitcher() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    height: 36,
    decoration: PetsLook.panel(radius: 18, alpha: .92),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('room-prev'),
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: 'Предыдущая комната',
          onPressed: () => _go(-1),
          icon: const Icon(Icons.chevron_left_rounded, color: PetsLook.deep),
        ),
        Text(room.title, key: const ValueKey('room-title'), style: PetsLook.title(15)),
        const SizedBox(width: 8),
        for (var i = 0; i < widget.rooms.length; i++)
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i == s.room % widget.rooms.length ? PetsLook.lavender : const Color(0xFFD8CCE6),
            ),
          ),
        IconButton(
          key: const ValueKey('room-next'),
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: 'Следующая комната',
          onPressed: () => _go(1),
          icon: const Icon(Icons.chevron_right_rounded, color: PetsLook.deep),
        ),
      ],
    ),
  );

  Widget _dock() => Container(
    constraints: const BoxConstraints(maxWidth: 560),
    height: 92,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: PetsLook.panel(radius: 26),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _DockButton(
          key: const ValueKey('dock-shop'),
          icon: Icons.shopping_bag_outlined,
          label: 'Магазин',
          onTap: () => _showShop(context, s),
        ),
        _DockButton(
          key: const ValueKey('dock-play'),
          icon: Icons.sports_baseball_outlined,
          label: 'Игра',
          meter: mood,
          meterColor: PetsLook.joy,
          onTap: asleep
              ? () => s._say('${pet.name} спит. Поиграем утром')
              : () {
                  s.scene.play();
                  unawaited(s._act(() => s.service.play(pet.id)));
                },
        ),
        _DockButton(
          key: const ValueKey('dock-food'),
          icon: Icons.restaurant_rounded,
          label: 'Еда',
          meter: satiety,
          meterColor: PetsLook.food,
          active: room.key == 'kitchen',
          onTap: () => _goTo('kitchen'),
        ),
        _DockButton(
          key: const ValueKey('dock-sleep'),
          icon: Icons.bedtime_outlined,
          label: 'Сон',
          meter: energy,
          meterColor: PetsLook.sleep,
          active: room.key == 'bedroom',
          onTap: () => _goTo('bedroom'),
        ),
        _DockButton(
          key: const ValueKey('dock-wardrobe'),
          icon: Icons.checkroom_outlined,
          label: 'Гардероб',
          onTap: () => _showWardrobe(context, s),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- room panels

class _FoodTray extends StatelessWidget {
  final _HomeState home;
  const _FoodTray({required this.home});

  @override
  Widget build(BuildContext context) {
    final s = home.s, o = home.o;
    final foods = shopItems.where((i) => i.kind == ShopKind.food).toList();
    return Container(
      key: const ValueKey('food-tray'),
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: PetsLook.panel(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('Угощение', style: PetsLook.title(17))),
              TextButton(onPressed: () => _showShop(context, s), child: const Text('В магазин')),
            ],
          ),
          Row(
            children: [
              for (final food in foods)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _FoodTile(
                      food: food,
                      count: o.inventory[food.id] ?? 0,
                      onTap: s.busy
                          ? null
                          : () async {
                              if ((o.inventory[food.id] ?? 0) <= 0) {
                                _showShop(context, s, kind: ShopKind.food);
                                return;
                              }
                              final eaten = await s._act(() => s.service.feed(home.pet.id, food.id));
                              if (eaten != null) s.scene.eat(treat: eaten.treat);
                            },
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FoodTile extends StatelessWidget {
  final ShopItem food;
  final int count;
  final VoidCallback? onTap;
  const _FoodTile({required this.food, required this.count, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: PetsLook.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: PetsLook.line, width: 1.5),
    ),
    child: InkWell(
      key: ValueKey('food-${food.id}'),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
            child: Column(
              children: [
                Image.asset(food.icon, height: 46, errorBuilder: (_, _, _) => const SizedBox(height: 46)),
                Text(food.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: PetsLook.ink)),
                Text(count > 0 ? '+${food.satietyHours} ч' : '${food.price} мон.',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: PetsLook.muted)),
              ],
            ),
          ),
          Positioned(
            right: 5,
            top: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: count > 0 ? PetsLook.lavender : PetsLook.food,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(count > 0 ? '×$count' : '+',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NightPanel extends StatelessWidget {
  final _HomeState home;
  const _NightPanel({required this.home});

  @override
  Widget build(BuildContext context) {
    final s = home.s, o = home.o;
    final off = o.lightsUntil != null && s.now.isBefore(o.lightsUntil!);
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: PetsLook.panel(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Спокойной ночи', style: PetsLook.title(17))),
              Text(
                home.asleep ? 'спит до ${PetRules.wakeHour}:00' : 'сон с ${PetRules.sleepHour}:00',
                style: const TextStyle(fontSize: 12, color: PetsLook.muted, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _WideButton(
                  key: const ValueKey('night-light'),
                  icon: off ? Icons.lightbulb_outline : Icons.nightlight_round,
                  title: off ? 'Включить свет' : 'Выключить свет',
                  subtitle: off ? 'разбудить' : 'уложить спать',
                  onTap: s.busy ? null : () => s._act(() => s.service.setLightsOff(!off)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _WideButton(
                  icon: Icons.headphones_rounded,
                  title: 'Аудио на ночь',
                  subtitle: 'аудиокниги',
                  onTap: () => s.widget.navigation.onSelect(PepeSection.audio),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- decorate

/// «Ремонт»: markers on the decor spots of the room. A marker opens the
/// item: show or hide it if bought, or buy it.
class _DecorateLayer extends StatelessWidget {
  final _HomeState home;
  final Size size;
  const _DecorateLayer({required this.home, required this.size});

  /// Screen point of a Blender position, with the camera of the scene.
  Offset? _project(PetRoom room, vm.Vector3 blender) {
    final p = blenderToScene(room.cameraPosition);
    final f = blenderToScene(room.cameraForward).normalized();
    final up0 = blenderToScene(room.cameraUp).normalized();
    final r = up0.cross(f).normalized();
    final u = f.cross(r).normalized();
    final aspect = size.width / size.height;
    final fovY = aspect > 1 ? 2 * math.atan(math.tan(room.fov / 2) / aspect) : room.fov;
    final tanY = math.tan(fovY / 2), tanX = tanY * aspect;
    final v = blenderToScene(blender) - p;
    final depth = v.dot(f);
    if (depth <= 0.05) return null;
    final nx = v.dot(r) / (depth * tanX), ny = v.dot(u) / (depth * tanY);
    return Offset((nx + 1) / 2 * size.width, (1 - ny) / 2 * size.height);
  }

  @override
  Widget build(BuildContext context) {
    final room = home.room, s = home.s, o = home.o;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: Row(
            children: [
              Expanded(
                child: Text('Ремонт · ${room.title}',
                    style: PetsLook.title(22).copyWith(color: Colors.white, shadows: const [
                      Shadow(color: Color(0xAA000000), blurRadius: 6),
                    ])),
              ),
              FilledButton(
                key: const ValueKey('decorate-done'),
                style: FilledButton.styleFrom(backgroundColor: PetsLook.lavender),
                onPressed: home.finishDecorating,
                child: const Text('Готово'),
              ),
            ],
          ),
        ),
        if (room.decor.isEmpty)
          Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(16),
              decoration: PetsLook.panel(),
              child: const Text(
                'Здесь пока нечего переставить: декор живёт в гостиной и спальне.',
                textAlign: TextAlign.center,
                style: TextStyle(color: PetsLook.ink, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        for (final spot in room.decor)
          Builder(
            builder: (context) {
              final at = _project(room, spot.position + vm.Vector3(0, 0, 0.25 * spot.scale));
              final item = shopItem(spot.id);
              if (at == null || item == null) return const SizedBox.shrink();
              final owned = o.owned.contains(spot.id);
              return Positioned(
                left: at.dx - 26,
                top: at.dy - 26,
                child: Tooltip(
                  message: item.title,
                  child: Material(
                    color: owned ? PetsLook.lavender : PetsLook.cream,
                    shape: const CircleBorder(side: BorderSide(color: PetsLook.line, width: 1.5)),
                    elevation: 4,
                    child: InkWell(
                      key: ValueKey('decor-${spot.id}'),
                      customBorder: const CircleBorder(),
                      onTap: () => _showDecorItem(context, s, item),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Image.asset(item.icon, width: 42, height: 42),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- widgets

class _LevelRing extends StatelessWidget {
  final int level;
  final double progress;
  const _LevelRing({required this.level, required this.progress});
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 62,
    height: 62,
    child: Stack(
      alignment: Alignment.center,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: PetsLook.cream,
            boxShadow: [BoxShadow(color: Color(0x40281A28), blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: SizedBox.expand(),
        ),
        SizedBox.expand(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 5,
              color: PetsLook.lavender,
              backgroundColor: const Color(0xFFE6DCEB),
            ),
          ),
        ),
        Text('$level', key: const ValueKey('pets-level'), style: PetsLook.title(21).copyWith(color: PetsLook.deep)),
      ],
    ),
  );
}

class _Coin extends StatelessWidget {
  final double size;
  const _Coin({this.size = 18});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: PetsLook.gold,
      border: Border.all(color: const Color(0xFFB8862A), width: 1.5),
    ),
    alignment: Alignment.center,
    child: Container(
      width: size * .5,
      height: size * .5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFB8862A), width: 1.2),
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  final Widget icon;
  final String text;
  final VoidCallback? onTap;
  const _Pill({super.key, required this.icon, required this.text, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: PetsLook.cream.withValues(alpha: .94),
    shape: const StadiumBorder(side: BorderSide(color: PetsLook.line, width: 1.5)),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: PetsLook.ink)),
          ],
        ),
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool dot;
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.dot = false});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          color: PetsLook.cream.withValues(alpha: .94),
          shape: const CircleBorder(side: BorderSide(color: PetsLook.line, width: 1.5)),
          elevation: 3,
          shadowColor: const Color(0x66281A28),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 46, height: 46, child: Icon(icon, color: PetsLook.deep, size: 23)),
          ),
        ),
        if (dot)
          const Positioned(
            right: -1,
            top: -1,
            child: CircleAvatar(radius: 6, backgroundColor: Color(0xFFE0536E)),
          ),
      ],
    ),
  );
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double? meter;
  final Color meterColor;
  final bool active;
  const _DockButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.meter,
    this.meterColor = PetsLook.joy,
    this.active = false,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: SizedBox(
      width: 64,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 42,
            decoration: BoxDecoration(
              color: active ? PetsLook.lavender : PetsLook.lavenderSoft,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: active ? Colors.white : PetsLook.deep),
          ),
          const SizedBox(height: 3),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: PetsLook.ink)),
          const SizedBox(height: 3),
          SizedBox(
            width: 34,
            height: 4,
            child: meter == null
                ? null
                : ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: meter!.clamp(0.0, 1.0),
                      color: meterColor,
                      backgroundColor: const Color(0xFFE6DCEB),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class _WideButton extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  const _WideButton({super.key, required this.icon, required this.title, required this.subtitle, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: PetsLook.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: PetsLook.line, width: 1.5),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: PetsLook.deep),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: PetsLook.ink)),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: PetsLook.muted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- starter

class _StarterPicker extends StatelessWidget {
  final bool busy;
  final ValueChanged<PetSpecies> onPick;
  const _StarterPicker({required this.busy, required this.onPick});

  @override
  Widget build(BuildContext context) => Theme(
    data: PetsLook.theme(context),
    child: Container(
      color: PetsLook.cream,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Выберите первого питомца', style: PetsLook.title(24)),
          const SizedBox(height: 6),
          const Text(
            'Чтение и прослушивание в PepeHub приносят монеты и опыт: '
            '1 минута — 1 монета, до 4 часов в день. Счёт начнётся с этого '
            'момента; прошлое чтение не учитывается. Двое других появятся '
            'позже — их можно будет вырастить из яиц.',
            style: TextStyle(color: PetsLook.muted),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final species in PetSpecies.values)
                SizedBox(
                  width: 220,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('starter-${species.name}'),
                      onTap: busy ? null : () => onPick(species),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Image.asset(eggIcon(species.name), height: 110,
                                errorBuilder: (_, _, _) => const Icon(Icons.egg, size: 80, color: PetsLook.lavender)),
                            const SizedBox(height: 8),
                            Text(species.label, style: PetsLook.title(18)),
                            Text(species.motto, textAlign: TextAlign.center, style: const TextStyle(color: PetsLook.muted)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
