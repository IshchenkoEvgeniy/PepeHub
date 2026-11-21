import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

/// Builds the 3D home; tests replace it (Flutter GPU is not available there).
typedef PetSceneBuilder = Widget Function(
  BuildContext context,
  Pet pet,
  Set<String> owned,
  List<PetEgg> eggs,
  PetSceneController controller,
);

Widget _defaultScene(
  BuildContext context,
  Pet pet,
  Set<String> owned,
  List<PetEgg> eggs,
  PetSceneController controller,
) => PetHomeScene(pet: pet, owned: owned, eggs: eggs, controller: controller);

/// The «Питомник» section: home with the 3D room, the pets, the shop and the
/// journal. Recounts reading when opened and when the app returns to front.
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

class _PetsSectionState extends State<PetsSection>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final service = PetsService(widget.repository, clock: widget.clock);
  late final tabs = TabController(length: 6, vsync: this);
  final scene = PetSceneController();
  PetsOverview? overview;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      await service.sync();
      final next = await service.overview();
      if (mounted) {
        setState(() {
          overview = next;
          error = null;
        });
      }
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

  @override
  Widget build(BuildContext context) => ShelfShell(
    title: 'Питомник',
    navigation: widget.navigation,
    actions: [
      if (kDebugMode && overview?.enabledAt != null)
        PopupMenuButton<int>(
          key: const ValueKey('pets-debug'),
          tooltip: 'Тест (отладка)',
          icon: const Icon(Icons.science_outlined),
          onSelected: (minutes) => _act(() async {
            if (minutes < 0) {
              await service.resetAll();
            } else {
              await service.addTestMinutes(minutes);
            }
          }),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 15, child: Text('+15 минут чтения')),
            PopupMenuItem(value: 60, child: Text('+1 час чтения')),
            PopupMenuItem(value: 240, child: Text('+4 часа чтения')),
            PopupMenuItem(value: -1, child: Text('Сбросить питомник')),
          ],
        ),
    ],
    body: _body(),
  );

  Widget _body() {
    final o = overview;
    if (o == null) {
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
    return Column(
      children: [
        _Summary(overview: o, now: service.clock()),
        TabBar(
          controller: tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Дом'),
            Tab(
              text: o.pets.any((p) => p.pathPending) ? 'Питомцы •' : 'Питомцы',
            ),
            Tab(text: o.eggs.any((e) => e.ready) ? 'Инкубатор •' : 'Инкубатор'),
            const Tab(text: 'Магазин'),
            const Tab(text: 'Достижения'),
            const Tab(text: 'Журнал'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: tabs,
            // The 3D home takes horizontal drags for the camera.
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _home(o),
              _PetsTab(
                overview: o,
                service: service,
                now: service.clock(),
                busy: busy,
                act: _act,
              ),
              _IncubatorTab(
                overview: o,
                service: service,
                busy: busy,
                act: _act,
                say: _say,
              ),
              _ShopTab(
                overview: o,
                service: service,
                busy: busy,
                onBuyEgg: (offer) async {
                  final done = await _act(() async {
                    await service.buyEgg(offer.species);
                    return true;
                  });
                  if (done == true) _say('Яйцо в инкубаторе');
                },
                onBuy: (item) async {
                  final done = await _act(() async {
                    await service.buy(item.id);
                    return true;
                  });
                  if (done == true) _say('Куплено: ${item.title}');
                },
              ),
              _AchievementsTab(
                overview: o,
                service: service,
                busy: busy,
                act: _act,
              ),
              _JournalTab(
                service: service,
                revision: o.balance ^ o.recent.length,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _home(PetsOverview o) {
    final pet = o.companion!;
    final foods = [
      for (final item in shopItems.where((i) => i.kind == ShopKind.food))
        if ((o.inventory[item.id] ?? 0) > 0) item,
    ];
    final palette = ShelfPalette.of(context);
    return Column(
      children: [
        Expanded(
          child: DragTarget<ShopItem>(
            onAcceptWithDetails: (details) async {
              final food = await _act(
                () => service.feed(pet.id, details.data.id),
              );
              if (food != null) scene.eat(treat: food.treat);
            },
            builder: (context, candidates, _) => DecoratedBox(
              decoration: BoxDecoration(
                border: candidates.isEmpty
                    ? null
                    : Border.all(color: palette.accent, width: 3),
              ),
              child: widget.sceneBuilder(context, pet, o.owned, o.eggs, scene),
            ),
          ),
        ),
        Material(
          color: palette.sidebar,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: foods.isEmpty
                  ? Center(
                      child: Text(
                        'Еды нет — загляните в магазин',
                        style: TextStyle(color: palette.muted),
                      ),
                    )
                  : ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      children: [
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              'Перетащите еду\nна питомца',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        for (final food in foods)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Draggable<ShopItem>(
                              data: food,
                              feedback: Material(
                                color: Colors.transparent,
                                child: _FoodChip(food, o.inventory[food.id]!),
                              ),
                              child: _FoodChip(food, o.inventory[food.id]!),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FoodChip extends StatelessWidget {
  final ShopItem food;
  final int count;
  const _FoodChip(this.food, this.count);
  @override
  Widget build(BuildContext context) => Chip(
    avatar: const Icon(Icons.restaurant_rounded, size: 18),
    label: Text('${food.title} ×$count'),
  );
}

// ---------------------------------------------------------------- summary

class _Summary extends StatelessWidget {
  final PetsOverview overview;
  final DateTime now;
  const _Summary({required this.overview, required this.now});

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final pet = o.companion!;
    final palette = ShelfPalette.of(context);
    final muted = TextStyle(color: palette.muted, fontSize: 12);
    String hm(int m) => '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
    final start = PetRules.totalXpForLevel(pet.level);
    final need = PetRules.xpForLevel(pet.level);
    final max = pet.level >= PetRules.maxLevel;
    Widget tile(IconData icon, String title, String subtitle, double? value) =>
        SizedBox(
          width: 210,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                Icon(icon, color: palette.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (value != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: LinearProgressIndicator(value: value),
                        ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Wrap(
        children: [
          tile(
            Icons.monetization_on_outlined,
            '${o.balance} монет',
            'Баланс',
            null,
          ),
          tile(
            Icons.pets,
            '${pet.name} · ур. ${pet.level}',
            max
                ? 'Максимальный уровень'
                : '${pet.stage.label} · опыт ${(pet.xp - start).floor()} / $need',
            max ? 1 : ((pet.xp - start) / need).clamp(0, 1).toDouble(),
          ),
          tile(
            Icons.timer_outlined,
            'Сегодня ${hm(o.todayCredited)} / ${hm(PetRules.dailyMinutes)}',
            'Минуты чтения и прослушивания',
            o.todayCredited / PetRules.dailyMinutes,
          ),
          tile(
            Icons.auto_stories_outlined,
            o.bookOfDay ?? 'Книга дня — свободно',
            o.bookOfDay == null
                ? 'Завершите книгу, прочитанную здесь от 1 часа'
                : 'Бонус за сегодня получен',
            null,
          ),
          tile(
            Icons.local_fire_department_outlined,
            'Серия ${o.streak.current} дн.',
            'Заморозок ${o.streak.freezes} из ${PetRules.maxFreezes} · от 15 мин в день',
            null,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- starter

class _StarterPicker extends StatelessWidget {
  final bool busy;
  final ValueChanged<PetSpecies> onPick;
  const _StarterPicker({required this.busy, required this.onPick});

  static const _colors = {
    PetSpecies.cat: Color(0xFF9AA3B0),
    PetSpecies.fox: Color(0xFFE8803A),
    PetSpecies.dragon: Color(0xFF4FB3A9),
  };

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Выберите первого питомца',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'Чтение и прослушивание в PepeHub приносят монеты и опыт: '
          '1 минута — 1 монета, до 4 часов в день. Счёт начнётся с этого '
          'момента; прошлое чтение не учитывается. Двое других появятся '
          'позже — их можно будет вырастить из яиц.',
          style: TextStyle(color: palette.muted),
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
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: _colors[species],
                            child: const Icon(
                              Icons.pets,
                              size: 40,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            species.label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            species.motto,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- journal

/// Every grant and purchase with its reason, newest first, paged lazily.
class _JournalTab extends StatefulWidget {
  final PetsService service;

  /// Changes whenever the ledger may have grown, to reload the first page.
  final int revision;
  const _JournalTab({required this.service, required this.revision});
  @override
  State<_JournalTab> createState() => _JournalTabState();
}

class _JournalTabState extends State<_JournalTab> {
  static const _page = 50;
  final entries = <PetLedgerEntry>[];
  bool loading = false, done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  @override
  void didUpdateWidget(_JournalTab old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) {
      entries.clear();
      done = false;
      unawaited(_more());
    }
  }

  Future<void> _more() async {
    if (loading || done) return;
    loading = true;
    final next = await widget.service.ledger(
      limit: _page,
      before: entries.isEmpty ? null : entries.last.id,
    );
    if (!mounted) return;
    setState(() {
      entries.addAll(next);
      done = next.length < _page;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    if (entries.isEmpty) {
      return Center(
        child: Text(
          done ? 'Пока пусто' : 'Загрузка…',
          style: TextStyle(color: palette.muted),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length + (done ? 0 : 1),
      itemBuilder: (context, i) {
        if (i >= entries.length) {
          unawaited(_more());
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final e = entries[i];
        return ListTile(
          dense: true,
          title: Text(e.note),
          subtitle: Text(e.day),
          trailing: Text(
            e.coins == 0 ? '—' : '${e.coins > 0 ? '+' : ''}${e.coins}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: e.coins < 0 ? palette.muted : null,
            ),
          ),
        );
      },
    );
  }
}
