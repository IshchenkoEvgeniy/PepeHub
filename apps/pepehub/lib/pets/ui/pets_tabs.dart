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

/// The pets at home and the profile of one: name, companion, growth, looks.
/// New species are bought in the shop (tab «Питомцы»).
class _PetsTab extends StatefulWidget {
  final PetsOverview overview;
  final PetsService service;
  final DateTime now;
  final bool busy;
  final _Act act;
  final VoidCallback onShop;
  const _PetsTab({
    required this.overview,
    required this.service,
    required this.now,
    required this.busy,
    required this.act,
    required this.onShop,
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
    final offers = widget.service.petOffers(o.pets);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Everyone at home.
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final other in o.pets)
              _PetChip(
                key: ValueKey('pet-${other.id}'),
                pet: other,
                companion: other.id == o.companion?.id,
                selected: other.id == p.id,
                onTap: () => setState(() => selected = other.id),
              ),
            for (final s in offers)
              _PetChip.offer(
                key: ValueKey('pet-offer-${s.name}'),
                species: s,
                onTap: widget.onShop,
              ),
          ],
        ),
        const Divider(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                p.name,
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
                icon: const Icon(Icons.home_outlined),
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
        _hint(
          context,
          'Растёт от чтения: малыш → детёныш (10-й уровень) → подросток '
          '(25-й) → взрослый (45-й).',
        ),
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
        _heading(context, 'Аксессуары'),
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

/// A pet at home (portrait, name, level) or, for a species not bought yet,
/// a faded portrait with its price.
class _PetChip extends StatelessWidget {
  final Pet? pet;
  final PetSpecies species;
  final bool companion, selected;
  final VoidCallback onTap;
  _PetChip({
    super.key,
    required Pet this.pet,
    required this.companion,
    required this.selected,
    required this.onTap,
  }) : species = PetSpecies.byId(pet.species) ?? PetSpecies.fox;
  const _PetChip.offer({super.key, required this.species, required this.onTap})
    : pet = null,
      companion = false,
      selected = false;

  @override
  Widget build(BuildContext context) {
    final p = pet;
    return Material(
      color: selected ? PetsLook.lavenderSoft : PetsLook.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? PetsLook.lavender : PetsLook.line,
          width: 2,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: 104,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
            child: Column(
              children: [
                SizedBox(
                  height: 72,
                  child: Opacity(
                    opacity: p == null ? .4 : 1,
                    child: Image.asset(
                      species.icon,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.pets, color: PetsLook.lavender),
                    ),
                  ),
                ),
                Text(
                  p == null ? species.label : p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: PetsLook.ink,
                  ),
                ),
                Text(
                  p == null
                      ? 'в магазине · $petPrice'
                      : '${companion ? 'компаньон · ' : ''}ур. ${p.level}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: PetsLook.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
    if (entries.isEmpty) {
      return Center(
        child: Text(
          done ? 'Пока пусто' : 'Загрузка…',
          style: const TextStyle(color: PetsLook.muted),
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
              color: e.coins < 0 ? PetsLook.muted : null,
            ),
          ),
        );
      },
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
