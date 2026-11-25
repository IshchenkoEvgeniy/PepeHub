part of 'pets_section.dart';

/// A cream sheet over the room. [builder] rebuilds whenever the overview
/// changes, so purchases and changes show at once (and in the 3D room above).
Future<void> _sheet(
  BuildContext context,
  _PetsSectionState s, {
  required String title,
  required Widget Function(BuildContext context, PetsOverview o) builder,
  double height = .86,
  Widget? trailing,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0x55201420),
  builder: (context) => Theme(
    data: PetsLook.theme(context),
    child: FractionallySizedBox(
      heightFactor: height,
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        decoration: PetsLook.panel(radius: 28),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(color: const Color(0xFFE0D3C0), borderRadius: BorderRadius.circular(3)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(child: Text(title, style: PetsLook.title(24))),
                  ?trailing,
                  ValueListenableBuilder<PetsOverview?>(
                    valueListenable: s.overview,
                    builder: (context, o, _) => o == null
                        ? const SizedBox.shrink()
                        : _Pill(icon: const _Coin(size: 18), text: '${o.balance}'),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: PetsLook.deep),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<PetsOverview?>(
                valueListenable: s.overview,
                builder: (context, o, _) => o == null ? const SizedBox.shrink() : builder(context, o),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

// ---------------------------------------------------------------- shop

const _shopTabs = <(String, List<ShopKind>)>[
  ('Еда', [ShopKind.food]),
  ('Декор', [ShopKind.decor]),
  ('Окрасы', [ShopKind.color]),
  ('Аксессуары', [ShopKind.accessory]),
  ('Яйца', []),
  ('Разное', [ShopKind.freeze, ShopKind.upgrade]),
];

Future<void> _showShop(BuildContext context, _PetsSectionState s, {ShopKind? kind}) {
  final initial = kind == null ? 0 : _shopTabs.indexWhere((t) => t.$2.contains(kind));
  return _sheet(
    context,
    s,
    title: 'Магазин',
    builder: (context, o) => _ShopView(s: s, o: o, initial: math.max(0, initial)),
  );
}

class _ShopView extends StatefulWidget {
  final _PetsSectionState s;
  final PetsOverview o;
  final int initial;
  const _ShopView({required this.s, required this.o, required this.initial});
  @override
  State<_ShopView> createState() => _ShopViewState();
}

class _ShopViewState extends State<_ShopView> {
  late int tab = widget.initial;

  @override
  Widget build(BuildContext context) {
    final o = widget.o, s = widget.s;
    final (_, kinds) = _shopTabs[tab];
    final cards = <Widget>[];
    if (kinds.isEmpty) {
      final free = o.incubatorSlots - o.eggs.length;
      for (final offer in s.service.eggOffers(o.pets, o.eggs)) {
        cards.add(_ShopCard(
          key: ValueKey('offer-${offer.species.name}'),
          icon: eggIcon(offer.species.name),
          title: offer.copy ? 'Копия: ${offer.species.label.toLowerCase()}' : offer.species.label,
          subtitle: '${offer.minutes ~/ 60} ч чтения',
          price: offer.price,
          enabled: !s.busy && free > 0 && o.balance >= offer.price,
          onBuy: () async {
            final done = await s._act(() async {
              await s.service.buyEgg(offer.species);
              return true;
            });
            if (done == true) s._say('Яйцо в инкубаторе');
          },
        ));
      }
      if (free <= 0) {
        cards.add(const _ShopNote('Инкубатор занят: яйцо высиживается чтением.'));
      }
    } else {
      for (final item in shopItems.where((i) => kinds.contains(i.kind))) {
        final owned = !item.kind.consumable && o.owned.contains(item.id);
        final have = o.inventory[item.id] ?? 0;
        final frozenFull = item.kind == ShopKind.freeze && o.streak.freezes >= PetRules.maxFreezes;
        cards.add(_ShopCard(
          key: ValueKey('shop-${item.id}'),
          icon: item.icon,
          title: item.title,
          subtitle: [
            if (item.kind == ShopKind.food && have > 0) 'есть ×$have',
            if (item.kind == ShopKind.freeze) 'в запасе ${o.streak.freezes}',
          ].join(' · '),
          price: item.price,
          status: item.rewardOnly ? 'Награда' : owned ? 'Куплено' : null,
          description: item.description,
          enabled: !s.busy && !item.rewardOnly && !owned && !frozenFull && o.balance >= item.price,
          onBuy: () async {
            final done = await s._act(() async {
              await s.service.buy(item.id);
              return true;
            });
            if (done == true) s._say('Куплено: ${item.title}');
          },
        ));
      }
    }
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (var i = 0; i < _shopTabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('shop-tab-$i'),
                    label: Text(_shopTabs[i].$1),
                    selected: i == tab,
                    selectedColor: PetsLook.lavender,
                    labelStyle: TextStyle(
                      color: i == tab ? Colors.white : PetsLook.ink,
                      fontWeight: FontWeight.w800,
                    ),
                    showCheckmark: false,
                    onSelected: (_) => setState(() => tab = i),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisExtent: 232,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            children: cards,
          ),
        ),
      ],
    );
  }
}

class _ShopNote extends StatelessWidget {
  final String text;
  const _ShopNote(this.text);
  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: PetsLook.muted)),
  );
}

class _ShopCard extends StatelessWidget {
  final String icon, title, subtitle;
  final String? status, description;
  final int price;
  final bool enabled;
  final VoidCallback onBuy;
  const _ShopCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.enabled,
    required this.onBuy,
    this.status,
    this.description,
  });

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: description == null
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (context) => Theme(
                data: PetsLook.theme(context),
                child: AlertDialog(
                  backgroundColor: PetsLook.cream,
                  title: Text(title, style: PetsLook.title(20)),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(icon, height: 140, errorBuilder: (_, _, _) => const SizedBox()),
                      const SizedBox(height: 8),
                      Text(description!, textAlign: TextAlign.center),
                    ],
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
                    if (status == null)
                      FilledButton(
                        onPressed: enabled
                            ? () {
                                Navigator.pop(context);
                                onBuy();
                              }
                            : null,
                        child: Text('Купить за $price'),
                      ),
                  ],
                ),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Colors.white, Color(0xFFF4EADB)], stops: [.3, 1]),
                ),
                padding: const EdgeInsets.all(4),
                child: Image.asset(icon, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.pets)),
              ),
            ),
            const SizedBox(height: 6),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: PetsLook.ink)),
            SizedBox(
              height: 16,
              child: Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: PetsLook.muted, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            if (status != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: status == 'Куплено' ? const Color(0xFFCFE6C9) : PetsLook.lavenderSoft,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(status!, style: const TextStyle(fontWeight: FontWeight.w900, color: PetsLook.ink)),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: PetsLook.gold,
                  foregroundColor: PetsLook.ink,
                  disabledBackgroundColor: const Color(0xFFEDE5D8),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                onPressed: enabled ? onBuy : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _Coin(size: 16),
                    const SizedBox(width: 6),
                    Text('$price', style: const TextStyle(fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- wardrobe

Future<void> _showWardrobe(BuildContext context, _PetsSectionState s) => _sheet(
  context,
  s,
  title: 'Гардероб',
  height: .5,
  builder: (context, o) => _WardrobeView(s: s, o: o),
);

class _WardrobeView extends StatefulWidget {
  final _PetsSectionState s;
  final PetsOverview o;
  const _WardrobeView({required this.s, required this.o});
  @override
  State<_WardrobeView> createState() => _WardrobeViewState();
}

class _WardrobeViewState extends State<_WardrobeView> {
  bool colors = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.o, s = widget.s, pet = o.companion!;
    final items = shopItems.where((i) => i.kind == (colors ? ShopKind.color : ShopKind.accessory)).toList();
    Widget tile(String key, String icon, String title, bool on, bool owned, VoidCallback? onTap) => Card(
      key: ValueKey(key),
      margin: EdgeInsets.zero,
      color: on ? PetsLook.lavenderSoft : PetsLook.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: on ? PetsLook.lavender : PetsLook.line, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                children: [
                  Expanded(
                    child: Opacity(
                      opacity: owned ? 1 : .45,
                      child: icon.isEmpty
                          ? const Icon(Icons.auto_awesome, color: PetsLook.lavender, size: 40)
                          : Image.asset(icon, errorBuilder: (_, _, _) => const SizedBox()),
                    ),
                  ),
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: PetsLook.ink)),
                  if (!owned)
                    const Text('в магазине', style: TextStyle(fontSize: 10, color: PetsLook.muted, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            if (on)
              const Positioned(
                right: 6,
                bottom: 6,
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: PetsLook.lavender,
                  child: Icon(Icons.check_rounded, size: 15, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.checkroom_outlined), label: Text('Аксессуары')),
              ButtonSegment(value: true, icon: Icon(Icons.palette_outlined), label: Text('Окрас')),
            ],
            selected: {colors},
            onSelectionChanged: (v) => setState(() => colors = v.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            colors
                ? 'Окрас меняет мех питомца.'
                : 'Ячеек: ${pet.accessories.length} из ${pet.accessorySlots}',
            style: const TextStyle(color: PetsLook.muted, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: GridView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              mainAxisExtent: 130,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            children: [
              if (colors)
                tile('color-natural', '', 'Природный', pet.color == null, true,
                    s.busy ? null : () => s._act(() => s.service.setColor(pet.id, null))),
              for (final item in items)
                () {
                  final owned = o.owned.contains(item.id);
                  final on = colors ? pet.color == item.id : pet.accessories[item.socket] == item.id;
                  return tile(
                    'wear-${item.id}',
                    item.icon,
                    item.title,
                    on,
                    owned,
                    s.busy
                        ? null
                        : !owned
                        ? () => s._say(item.rewardOnly ? '«${item.title}» — награда за достижение' : 'Сначала купите в магазине')
                        : colors
                        ? () => s._act(() => s.service.setColor(pet.id, item.id))
                        : () => s._act(() => s.service.setAccessory(pet.id, item.socket!, on ? null : item.id)),
                  );
                }(),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- pets, achievements, album

enum _PetsWindowKind { pets, achievements, album }

Future<void> _showPetsWindow(BuildContext context, _PetsSectionState s, _PetsWindowKind kind) => switch (kind) {
  _PetsWindowKind.pets => _sheet(
      context,
      s,
      title: 'Питомцы',
      builder: (context, o) => DefaultTabController(
        length: 2,
        child: Column(
          children: [
            TabBar(
              labelColor: PetsLook.deep,
              indicatorColor: PetsLook.lavender,
              tabs: [
                Tab(text: o.pets.any((p) => p.pathPending) ? 'Питомцы •' : 'Питомцы'),
                Tab(text: o.eggs.any((e) => e.ready) ? 'Инкубатор •' : 'Инкубатор'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _PetsTab(overview: o, service: s.service, now: s.now, busy: s.busy, act: s._act),
                  _IncubatorTab(overview: o, service: s.service, busy: s.busy, act: s._act, say: s._say),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  _PetsWindowKind.achievements => _sheet(
      context,
      s,
      title: 'Достижения',
      builder: (context, o) => _AchievementsTab(overview: o, service: s.service, busy: s.busy, act: s._act),
    ),
  _PetsWindowKind.album => _sheet(
      context,
      s,
      title: 'Альбом',
      builder: (context, o) => DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              labelColor: PetsLook.deep,
              indicatorColor: PetsLook.lavender,
              tabs: [Tab(text: 'Снимки'), Tab(text: 'Журнал')],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _AlbumView(o: o, rooms: s.rooms ?? const []),
                  _JournalTab(service: s.service, revision: o.balance ^ o.recent.length),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
};

/// Photos of the pet's milestones: the first meeting, levels, the path and
/// every unlocked achievement; locked ones wait as empty frames.
class _AlbumView extends StatelessWidget {
  final PetsOverview o;
  final List<PetRoom> rooms;
  const _AlbumView({required this.o, required this.rooms});

  @override
  Widget build(BuildContext context) {
    final pet = o.companion!;
    String bg(int i) => rooms.isEmpty ? '' : rooms[i % rooms.length].background;
    final shots = <(String, String, IconData)>[
      ('Первая встреча', bg(0), Icons.pets_rounded),
      for (final level in [10, 25, 45, 70, 100])
        if (pet.level >= level) ('Уровень $level', bg(level), Icons.trending_up_rounded),
      if (pet.pathInfo != null) ('Путь: ${pet.pathInfo!.label}', bg(2), Icons.alt_route_rounded),
      for (final a in petAchievements)
        if (o.achievements.contains(a.id)) (a.title, bg(a.title.length), Icons.emoji_events_outlined),
    ];
    final locked = petAchievements.where((a) => !o.achievements.contains(a.id)).take(4).toList();
    return GridView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisExtent: 220,
        crossAxisSpacing: 14,
        mainAxisSpacing: 16,
      ),
      children: [
        for (var i = 0; i < shots.length; i++)
          Transform.rotate(
            angle: (i.isEven ? -1 : 1) * 0.03,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [BoxShadow(color: Color(0x33281A28), blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: shots[i].$2.isEmpty
                          ? const ColoredBox(color: PetsLook.lavenderSoft, child: SizedBox.expand())
                          : Image.asset(shots[i].$2, fit: BoxFit.cover, alignment: const Alignment(0, .35)),
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(shots[i].$3, size: 16),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(shots[i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: PetsLook.ink)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final a in locked)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFC9B49A), width: 2),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add_photo_alternate_outlined, size: 38, color: Color(0xFFB9A285)),
                const SizedBox(height: 8),
                Text(a.title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, color: PetsLook.muted)),
                Text(a.description, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: PetsLook.muted)),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- reading

Future<void> _showReadingSheet(BuildContext context, _PetsSectionState s) {
  final o = s.overview.value;
  if (o != null && o.companion!.satiety(s.now) <= 0) {
    final i = s.rooms?.indexWhere((r) => r.key == 'kitchen') ?? -1;
    if (i >= 0) s.setRoom(i);
    return Future.value();
  }
  return _sheet(
    context,
    s,
    title: 'Книга или аудио',
    height: .46,
    builder: (context, o) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Сегодня засчитано ${_hm(o.todayCredited)} из ${_hm(PetRules.dailyMinutes)}. '
            '${o.bookOfDay == null ? 'Книга дня ещё свободна: дочитайте книгу, прочитанную здесь от часа.' : 'Книга дня: ${o.bookOfDay}.'}',
            style: const TextStyle(color: PetsLook.muted, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _BigChoice(
                  key: const ValueKey('read-books'),
                  icon: Icons.menu_book_rounded,
                  label: 'Читать',
                  onTap: () {
                    Navigator.pop(context);
                    s.widget.navigation.onSelect(PepeSection.books);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigChoice(
                  key: const ValueKey('read-audio'),
                  icon: Icons.headphones_rounded,
                  label: 'Слушать',
                  onTap: () {
                    Navigator.pop(context);
                    s.widget.navigation.onSelect(PepeSection.audio);
                  },
                ),
              ),
            ],
          ),
          const Spacer(),
          Text('${o.companion!.name} читает вместе с вами: минуты превращаются в монеты и опыт.',
              textAlign: TextAlign.center, style: const TextStyle(color: PetsLook.muted, fontSize: 12)),
        ],
      ),
    ),
  );
}

class _BigChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _BigChoice({super.key, required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: PetsLook.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: PetsLook.line, width: 2),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: SizedBox(
        height: 76,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 30, color: PetsLook.deep),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: PetsLook.ink)),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------- decor item

Future<void> _showDecorItem(BuildContext context, _PetsSectionState s, ShopItem item) => _sheet(
  context,
  s,
  title: item.title,
  height: .5,
  builder: (context, o) {
    final owned = o.owned.contains(item.id);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        children: [
          Expanded(child: Image.asset(item.icon, errorBuilder: (_, _, _) => const SizedBox())),
          Text(item.description, textAlign: TextAlign.center, style: const TextStyle(color: PetsLook.muted)),
          const SizedBox(height: 12),
          if (owned)
            const Text('Уже стоит в комнате', style: TextStyle(fontWeight: FontWeight.w800, color: PetsLook.deep))
          else
            FilledButton(
              key: ValueKey('decor-buy-${item.id}'),
              onPressed: s.busy || o.balance < item.price
                  ? null
                  : () async {
                      final done = await s._act(() async {
                        await s.service.buy(item.id);
                        return true;
                      });
                      if (done == true) s._say('${item.title} в комнате');
                    },
              child: Text('Купить за ${item.price}'),
            ),
        ],
      ),
    );
  },
);

// ---------------------------------------------------------------- reward

/// «Пока вас не было»: what reading earned since the last visit.
Future<void> showRewardDialog(BuildContext context, PetsOverview o) {
  final u = o.unseen;
  final pet = o.companion!;
  Widget line(IconData icon, String text, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: PetsLook.lavenderSoft, borderRadius: BorderRadius.circular(11)),
          child: Icon(icon, size: 19, color: PetsLook.deep),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, color: PetsLook.ink))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w900, color: PetsLook.ink)),
      ],
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Theme(
      data: PetsLook.theme(context),
      child: Dialog(
        backgroundColor: PetsLook.cream,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Пока вас не было', textAlign: TextAlign.center, style: PetsLook.title(24)),
                const SizedBox(height: 10),
                if (u.minutes > 0) line(Icons.menu_book_rounded, 'Чтение и прослушивание', '${u.minutes} мин'),
                if (u.book != null) line(Icons.star_rounded, 'Книга дня: ${u.book}', ''),
                for (final note in u.notes.take(4)) line(Icons.card_giftcard_rounded, note, ''),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: const Color(0xFFFBF0D2), borderRadius: BorderRadius.circular(18)),
                        child: Column(
                          children: [
                            const _Coin(size: 28),
                            Text('+${u.coins}', style: PetsLook.title(24)),
                            const Text('монеты', style: TextStyle(color: PetsLook.muted, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: const Color(0xFFEFE6FA), borderRadius: BorderRadius.circular(18)),
                        child: Column(
                          children: [
                            Text(pet.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w900, color: PetsLook.ink)),
                            Text('+${u.xp} оп.', style: PetsLook.title(24)),
                            Text('ур. ${pet.level}', style: const TextStyle(color: PetsLook.muted, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('reward-take'),
                  style: FilledButton.styleFrom(
                    backgroundColor: PetsLook.lavender,
                    minimumSize: const Size.fromHeight(50),
                    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Забрать'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
