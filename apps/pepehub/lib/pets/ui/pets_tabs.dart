part of 'pets_section.dart';

/// Runs a user action with the section's error handling and refresh.
typedef _Act = Future<T?> Function<T>(Future<T> Function() action);

Widget _heading(BuildContext context, String text, {String? trailing}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: TextStyle(color: ShelfPalette.of(context).muted),
            ),
        ],
      ),
    );

Widget _hint(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
  child: Text(text, style: TextStyle(color: ShelfPalette.of(context).muted)),
);

Future<bool> _confirm(
  BuildContext context,
  String title,
  String text,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ==
    true;

String _hm(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

// ---------------------------------------------------------------- pets tab

/// The collection and the profile of one pet: path, talents, merging,
/// colors and accessories.
class _PetsTab extends StatefulWidget {
  final PetsOverview overview;
  final PetsService service;
  final DateTime now;
  final bool busy;
  final _Act act;
  const _PetsTab({
    required this.overview,
    required this.service,
    required this.now,
    required this.busy,
    required this.act,
  });

  @override
  State<_PetsTab> createState() => _PetsTabState();
}

class _PetsTabState extends State<_PetsTab> {
  String? selected;

  PetsOverview get o => widget.overview;

  Pet get pet =>
      o.pets.where((p) => p.id == selected).firstOrNull ?? o.companion!;

  Future<void> _rename(Pet pet) async {
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
    if (name != null) {
      await widget.act(() => widget.service.rename(pet.id, name));
    }
  }

  Future<void> _choosePath(Pet pet, PetPath path) async {
    if (!await _confirm(
      context,
      'Путь: ${path.label}',
      '${path.description}. Выбор делается один раз: '
          'с 45-го уровня ${pet.name} вырастет в этом облике.',
      'Выбрать',
    )) {
      return;
    }
    await widget.act(() => widget.service.choosePath(pet.id, path));
  }

  @override
  Widget build(BuildContext context) {
    final p = pet;
    final palette = ShelfPalette.of(context);
    final species = PetSpecies.byId(p.species);
    final companion = p.id == o.companion?.id;
    final busy = widget.busy;
    Widget row(String label, String value) => ListTile(
      dense: true,
      title: Text(label),
      trailing: Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    final colors = shopItems.where(
      (i) => i.kind == ShopKind.color && o.owned.contains(i.id),
    );
    final accessories = shopItems
        .where((i) => i.kind == ShopKind.accessory && o.owned.contains(i.id))
        .toList();
    final satiety = p.satiety(widget.now);
    final step = widget.service.nextRank(p);
    final copies = o.reserve[p.species] ?? 0;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Collection.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final other in o.pets)
              ChoiceChip(
                key: ValueKey('pet-${other.id}'),
                avatar: Icon(
                  other.id == o.companion?.id ? Icons.star : Icons.pets,
                  size: 18,
                ),
                label: Text(
                  '${other.name} · ${other.level}'
                  '${other.rank > 0 ? ' ${rankStars(other.rank)}' : ''}',
                ),
                selected: other.id == p.id,
                onSelected: (_) => setState(() => selected = other.id),
              ),
          ],
        ),
        if (o.reserve.isNotEmpty)
          _hint(
            context,
            'Запас копий: ${o.reserve.entries.map((e) => '${PetSpecies.byId(e.key)?.label ?? e.key} ×${e.value}').join(', ')}',
          ),
        const Divider(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                '${p.name}${p.rank > 0 ? '  ${rankStars(p.rank)}' : ''}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Переименовать',
              onPressed: busy ? null : () => _rename(p),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        Text(
          [
            species?.label ?? p.species,
            if (p.pathInfo != null) p.pathInfo!.label,
            companion
                ? 'компаньон: получает весь опыт'
                : 'получает 10% опыта компаньона',
          ].join(' · '),
          style: TextStyle(color: palette.muted),
        ),
        if (!companion)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const ValueKey('make-companion'),
                onPressed: busy
                    ? null
                    : () => widget.act(() => widget.service.setCompanion(p.id)),
                icon: const Icon(Icons.star_outline),
                label: const Text('Сделать компаньоном'),
              ),
            ),
          ),
        row('Уровень', '${p.level}'),
        row('Стадия', p.stage.label),
        row('Возраст', PetRules.ageForLevel(p.level)),
        row(
          'Сытость',
          satiety <= 0 ? 'голоден' : '${(satiety * 100).round()}%',
        ),
        // Path.
        _heading(context, 'Путь развития'),
        if (p.pathInfo != null)
          _hint(context, '${p.pathInfo!.label}: ${p.pathInfo!.description}.')
        else if (!p.pathPending)
          _hint(
            context,
            'Выбор пути откроется на ${PetRules.pathLevel}-м уровне.',
          )
        else
          for (final path in PetPath.of(p.species))
            Card(
              child: ListTile(
                key: ValueKey('path-${path.name}'),
                title: Text(path.label),
                subtitle: Text(path.description),
                trailing: FilledButton.tonal(
                  onPressed: busy ? null : () => _choosePath(p, path),
                  child: const Text('Выбрать'),
                ),
              ),
            ),
        // Talents.
        _heading(
          context,
          'Таланты',
          trailing: 'Очков: ${p.talentPointsFree} из ${p.talentPoints}',
        ),
        for (final t in petTalents)
          ListTile(
            dense: true,
            leading: Icon(
              p.talents.contains(t.id)
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: p.talents.contains(t.id) ? palette.accent : palette.muted,
            ),
            title: Text(t.title),
            subtitle: Text(
              '${t.description} Цена ${t.cost}, с ${t.minLevel}-го уровня.',
            ),
            trailing: p.talents.contains(t.id)
                ? null
                : TextButton(
                    key: ValueKey('talent-${t.id}'),
                    onPressed:
                        busy ||
                            p.level < t.minLevel ||
                            p.talentPointsFree < t.cost
                        ? null
                        : () => widget.act(
                            () => widget.service.learnTalent(p.id, t.id),
                          ),
                    child: const Text('Изучить'),
                  ),
          ),
        if (p.talents.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy || o.balance < talentResetPrice
                  ? null
                  : () async {
                      if (await _confirm(
                        context,
                        'Сбросить таланты?',
                        'Все очки вернутся, сброс стоит $talentResetPrice монет.',
                        'Сбросить',
                      )) {
                        await widget.act(
                          () => widget.service.resetTalents(p.id),
                        );
                      }
                    },
              icon: const Icon(Icons.restart_alt),
              label: Text('Сбросить за $talentResetPrice'),
            ),
          ),
        // Merge.
        _heading(context, 'Объединение'),
        if (p.unique)
          _hint(context, 'Уникальный питомец не объединяется.')
        else if (step == null)
          _hint(context, 'Высший ранг ★★★ получен.')
        else ...[
          _hint(
            context,
            'Следующий ранг ${step.label}: ${step.gives}. Нужно: '
            '${step.level}-й уровень (сейчас ${p.level}), копий в запасе '
            '${step.copies} (есть $copies), ${step.fee} монет.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const ValueKey('merge'),
              onPressed:
                  busy ||
                      p.level < step.level ||
                      copies < step.copies ||
                      o.balance < step.fee
                  ? null
                  : () => widget.act(() => widget.service.merge(p.id)),
              child: Text('Объединить за ${step.fee}'),
            ),
          ),
          _hint(context, 'Копии вылупляются из яиц копий в инкубаторе.'),
        ],
        // Looks.
        _heading(context, 'Окрас'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Природный'),
              selected: p.color == null,
              onSelected: busy
                  ? null
                  : (_) =>
                        widget.act(() => widget.service.setColor(p.id, null)),
            ),
            for (final c in colors)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: c.tint),
                label: Text(c.title),
                selected: p.color == c.id,
                onSelected: busy
                    ? null
                    : (_) =>
                          widget.act(() => widget.service.setColor(p.id, c.id)),
              ),
          ],
        ),
        if (colors.isEmpty) _hint(context, 'Новые окрасы — в магазине.'),
        _heading(
          context,
          'Аксессуары',
          trailing: 'Ячеек: ${p.accessories.length} из ${p.accessorySlots}',
        ),
        for (final item in accessories)
          SwitchListTile(
            title: Text(item.title),
            value: p.accessories[item.socket] == item.id,
            onChanged: busy
                ? null
                : (on) => widget.act(
                    () => widget.service.setAccessory(
                      p.id,
                      item.socket!,
                      on ? item.id : null,
                    ),
                  ),
          ),
        if (accessories.isEmpty)
          _hint(context, 'Шарф и шапочка — в магазине, очки — за достижение.'),
      ],
    );
  }
}

// ---------------------------------------------------------------- incubator

class _IncubatorTab extends StatelessWidget {
  final PetsOverview overview;
  final PetsService service;
  final bool busy;
  final _Act act;
  final void Function(String) say;
  const _IncubatorTab({
    required this.overview,
    required this.service,
    required this.busy,
    required this.act,
    required this.say,
  });

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final palette = ShelfPalette.of(context);
    final offers = service.eggOffers(o.pets, o.eggs);
    final free = o.incubatorSlots - o.eggs.length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _hint(
          context,
          'Яйцо высиживается чтением: ему идут те же засчитанные минуты, '
          'что и монеты. Минуты до покупки не считаются.',
        ),
        _heading(
          context,
          'Слоты',
          trailing: 'Занято ${o.eggs.length} из ${o.incubatorSlots}',
        ),
        for (final egg in o.eggs)
          Card(
            child: ListTile(
              key: ValueKey('egg-${egg.id}'),
              leading: CircleAvatar(
                backgroundColor: eggColors[PetSpecies.byId(egg.species)],
                child: const Icon(Icons.egg, color: Colors.white),
              ),
              title: Text(
                '${egg.copy ? 'Копия: ' : ''}'
                '${PetSpecies.byId(egg.species)?.label ?? egg.species}',
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: LinearProgressIndicator(value: egg.fraction),
                  ),
                  Text(
                    egg.ready
                        ? 'Готово к вылуплению'
                        : '${_hm(math.min(egg.progress, egg.minutes))} из ${_hm(egg.minutes)}',
                  ),
                ],
              ),
              trailing: egg.ready
                  ? FilledButton(
                      key: ValueKey('hatch-${egg.id}'),
                      onPressed: busy
                          ? null
                          : () async {
                              final id = await act(() => service.hatch(egg.id));
                              say(
                                id == null
                                    ? 'Копия ушла в запас'
                                    : 'Новый питомец! Он на вкладке «Питомцы»',
                              );
                            },
                      child: const Text('Вылупить'),
                    )
                  : null,
            ),
          ),
        for (var i = 0; i < free; i++)
          Card(
            child: ListTile(
              leading: Icon(Icons.egg_outlined, color: palette.muted),
              title: const Text('Свободный слот'),
              subtitle: const Text('Купите яйцо ниже'),
            ),
          ),
        if (o.incubatorSlots < 2)
          _hint(
            context,
            'Второй слот продаётся в магазине за $incubatorSlotPrice монет.',
          ),
        _heading(context, 'Яйца'),
        for (final offer in offers)
          _EggOfferTile(
            offer: offer,
            enabled: !busy && free > 0 && o.balance >= offer.price,
            onBuy: () async {
              final done = await act(() async {
                await service.buyEgg(offer.species);
                return true;
              });
              if (done == true) say('Яйцо в инкубаторе');
            },
          ),
        if (free <= 0) _hint(context, 'Все слоты заняты.'),
      ],
    );
  }
}

class _EggOfferTile extends StatelessWidget {
  final PetEggOffer offer;
  final bool enabled;
  final VoidCallback onBuy;
  const _EggOfferTile({
    required this.offer,
    required this.enabled,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: ValueKey('offer-${offer.species.name}'),
      leading: CircleAvatar(
        backgroundColor: eggColors[offer.species],
        child: const Icon(Icons.egg, color: Colors.white),
      ),
      title: Text(
        offer.copy
            ? 'Яйцо копии: ${offer.species.label.toLowerCase()}'
            : 'Яйцо: ${offer.species.label.toLowerCase()}',
      ),
      subtitle: Text(
        offer.copy
            ? 'Копия ждёт в запасе и нужна для объединения. '
                  '${offer.minutes ~/ 60} ч чтения.'
            : 'Новый питомец. ${offer.minutes ~/ 60} ч чтения.',
      ),
      trailing: FilledButton.tonal(
        onPressed: enabled ? onBuy : null,
        child: Text('${offer.price}'),
      ),
    ),
  );
}

// ---------------------------------------------------------------- shop tab

class _ShopTab extends StatelessWidget {
  final PetsOverview overview;
  final PetsService service;
  final bool busy;
  final ValueChanged<ShopItem> onBuy;
  final ValueChanged<PetEggOffer> onBuyEgg;
  const _ShopTab({
    required this.overview,
    required this.service,
    required this.busy,
    required this.onBuy,
    required this.onBuyEgg,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final free = overview.incubatorSlots - overview.eggs.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        for (final kind in ShopKind.values) ...[
          _heading(context, kind.label),
          if (kind == ShopKind.upgrade)
            for (final offer in service.eggOffers(overview.pets, overview.eggs))
              _EggOfferTile(
                offer: offer,
                enabled: !busy && free > 0 && overview.balance >= offer.price,
                onBuy: () => onBuyEgg(offer),
              ),
          for (final item in shopItems.where(
            (i) => i.kind == kind && !i.rewardOnly,
          ))
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

// ---------------------------------------------------------------- achievements

class _AchievementsTab extends StatelessWidget {
  final PetsOverview overview;
  final PetsService service;
  final bool busy;
  final _Act act;
  const _AchievementsTab({
    required this.overview,
    required this.service,
    required this.busy,
    required this.act,
  });

  String _reward(PetAchievement a) => [
    if (a.coins > 0) '${a.coins} монет',
    if (a.item != null) shopItem(a.item!)?.title ?? a.item!,
    if (a.honor != null) 'титул «${a.honor}»',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final palette = ShelfPalette.of(context);
    final honors = petAchievements.where(
      (a) => a.honor != null && o.achievements.contains(a.id),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _hint(
          context,
          'Получено ${o.achievements.length} из ${petAchievements.length}. '
          'Считается с момента включения Питомника.',
        ),
        if (honors.isNotEmpty) ...[
          _heading(context, 'Титул'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Без титула'),
                selected: o.honor == null,
                onSelected: busy
                    ? null
                    : (_) => act(() => service.setHonor(null)),
              ),
              for (final a in honors)
                ChoiceChip(
                  label: Text(a.honor!),
                  selected: o.honor == a.id,
                  onSelected: busy
                      ? null
                      : (_) => act(() => service.setHonor(a.id)),
                ),
            ],
          ),
        ],
        _heading(context, 'Достижения'),
        for (final a in petAchievements)
          Builder(
            builder: (context) {
              final done = o.achievements.contains(a.id);
              final value = o.progress.of(a.metric);
              return ListTile(
                key: ValueKey('ach-${a.id}'),
                leading: Icon(
                  done ? Icons.emoji_events : Icons.emoji_events_outlined,
                  color: done ? palette.accent : palette.muted,
                ),
                title: Text(a.title),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${a.description} Награда: ${_reward(a)}.'),
                    if (!done)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: LinearProgressIndicator(
                          value: (value / a.target).clamp(0, 1).toDouble(),
                        ),
                      ),
                  ],
                ),
                trailing: Text(
                  done
                      ? 'Получено'
                      : '${math.min(value, a.target)} / ${a.target}',
                  style: TextStyle(color: palette.muted),
                ),
              );
            },
          ),
      ],
    );
  }
}
