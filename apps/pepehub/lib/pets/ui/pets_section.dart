import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../diagnostics/error_log.dart';
import '../../diagnostics/user_message.dart';
import '../../ui/shelf_components.dart';
import '../pet_catalog.dart';
import '../pet_rules.dart';
import '../pets_service.dart';
import 'pet_scene.dart';

/// Builds the 3D home; tests replace it (Flutter GPU is not available there).
typedef PetSceneBuilder = Widget Function(
  BuildContext context,
  Pet pet,
  Set<String> owned,
  PetSceneController controller,
);

Widget _defaultScene(
  BuildContext context,
  Pet pet,
  Set<String> owned,
  PetSceneController controller,
) => PetHomeScene(pet: pet, owned: owned, controller: controller);

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
  late final tabs = TabController(length: 4, vsync: this);
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
          isScrollable: false,
          tabs: const [
            Tab(text: 'Дом'),
            Tab(text: 'Питомцы'),
            Tab(text: 'Магазин'),
            Tab(text: 'Журнал'),
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
                now: service.clock(),
                busy: busy,
                onRename: (pet, name) =>
                    _act(() => service.rename(pet.id, name)),
                onColor: (pet, color) =>
                    _act(() => service.setColor(pet.id, color)),
                onAccessory: (pet, socket, item) =>
                    _act(() => service.setAccessory(pet.id, socket, item)),
              ),
              _ShopTab(
                overview: o,
                busy: busy,
                onBuy: (item) async {
                  final done = await _act(() async {
                    await service.buy(item.id);
                    return true;
                  });
                  if (done == true) _say('Куплено: ${item.title}');
                },
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
              child: widget.sceneBuilder(context, pet, o.owned, scene),
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

// ---------------------------------------------------------------- pets tab

class _PetsTab extends StatelessWidget {
  final PetsOverview overview;
  final DateTime now;
  final bool busy;
  final void Function(Pet pet, String name) onRename;
  final void Function(Pet pet, String? color) onColor;
  final void Function(Pet pet, PetSocket socket, String? item) onAccessory;
  const _PetsTab({
    required this.overview,
    required this.now,
    required this.busy,
    required this.onRename,
    required this.onColor,
    required this.onAccessory,
  });

  Future<void> _rename(BuildContext context, Pet pet) async {
    final controller = TextEditingController(text: pet.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Имя питомца'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) onRename(pet, name);
  }

  @override
  Widget build(BuildContext context) {
    final pet = overview.companion!;
    final palette = ShelfPalette.of(context);
    final species = PetSpecies.byId(pet.species);
    final colors = shopItems.where(
      (i) => i.kind == ShopKind.color && overview.owned.contains(i.id),
    );
    final satiety = pet.satiety(now);
    Widget row(String label, String value) => ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                pet.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Переименовать',
              onPressed: busy ? null : () => _rename(context, pet),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        Text(
          '${species?.label ?? pet.species} · компаньон: получает весь опыт',
          style: TextStyle(color: palette.muted),
        ),
        row('Уровень', '${pet.level}'),
        row('Стадия', pet.stage.label),
        row('Возраст', PetRules.ageForLevel(pet.level)),
        row(
          'Сытость',
          satiety <= 0 ? 'голоден' : '${(satiety * 100).round()}%',
        ),
        const Divider(),
        Text('Окрас', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Природный'),
              selected: pet.color == null,
              onSelected: busy ? null : (_) => onColor(pet, null),
            ),
            for (final c in colors)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: c.tint),
                label: Text(c.title),
                selected: pet.color == c.id,
                onSelected: busy ? null : (_) => onColor(pet, c.id),
              ),
          ],
        ),
        if (colors.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Новые окрасы — в магазине.',
              style: TextStyle(color: palette.muted),
            ),
          ),
        const SizedBox(height: 16),
        Text('Аксессуары', style: Theme.of(context).textTheme.titleSmall),
        for (final item in shopItems.where(
          (i) => i.kind == ShopKind.accessory && overview.owned.contains(i.id),
        ))
          SwitchListTile(
            title: Text(item.title),
            value: pet.accessories[item.socket] == item.id,
            onChanged: busy
                ? null
                : (on) => onAccessory(pet, item.socket!, on ? item.id : null),
          ),
        if (!shopItems.any(
          (i) => i.kind == ShopKind.accessory && overview.owned.contains(i.id),
        ))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Шарф и шапочка — в магазине.',
              style: TextStyle(color: palette.muted),
            ),
          ),
        const Divider(height: 32),
        Text('Скоро', style: Theme.of(context).textTheme.titleSmall),
        for (final other in PetSpecies.values.where((s) => s != species))
          ListTile(
            leading: const Icon(Icons.egg_outlined),
            title: Text(other.label),
            subtitle: const Text('Появится яйцом в следующем обновлении'),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- shop tab

class _ShopTab extends StatelessWidget {
  final PetsOverview overview;
  final bool busy;
  final ValueChanged<ShopItem> onBuy;
  const _ShopTab({
    required this.overview,
    required this.busy,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        for (final kind in ShopKind.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
            child: Text(
              kind.label,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final item in shopItems.where((i) => i.kind == kind))
            Builder(
              builder: (context) {
                final owned =
                    !kind.consumable && overview.owned.contains(item.id);
                final have = overview.inventory[item.id] ?? 0;
                final frozenFull =
                    kind == ShopKind.freeze &&
                    overview.streak.freezes >= PetRules.maxFreezes;
                final affordable = overview.balance >= item.price;
                return Card(
                  child: ListTile(
                    key: ValueKey('shop-${item.id}'),
                    title: Text(item.title),
                    subtitle: Text(
                      [
                        item.description,
                        if (kind == ShopKind.food && have > 0) 'Есть: $have',
                        if (kind == ShopKind.freeze)
                          'В запасе: ${overview.streak.freezes}',
                      ].join(' · '),
                    ),
                    trailing: owned
                        ? Text(
                            'Куплено',
                            style: TextStyle(color: palette.muted),
                          )
                        : FilledButton.tonal(
                            onPressed: busy || !affordable || frozenFull
                                ? null
                                : () => onBuy(item),
                            child: Text('${item.price}'),
                          ),
                  ),
                );
              },
            ),
        ],
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
