part of 'pets_section.dart';

/// «Игра»: play in the room, or one of the mini-games. Mini-games pay coins
/// (up to [PetGames.dailyCoins] a day for all of them) and cheer the pet up.
Future<void> _showGames(BuildContext context, _HomeState home) {
  final s = home.s;
  return _sheet(
    context,
    s,
    title: 'Игра',
    height: .56,
    builder: (sheet, o) {
      final left = math.max(0, PetGames.dailyCoins - o.gameCoinsToday);
      Future<void> start(PetGame game) async {
        Navigator.pop(sheet);
        await _playGame(context, home, game);
      }

      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        children: [
          Text(
            left > 0
                ? 'Мини-игры сегодня ещё принесут до $left монет.'
                : 'Монеты за игры на сегодня собраны — играть можно и так.',
            style: const TextStyle(
              color: PetsLook.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          _GameCard(
            key: const ValueKey('game-room'),
            icon: Icons.sports_baseball_outlined,
            title: 'Поиграть в комнате',
            subtitle: 'Мяч и обнимашки — настроение лучше.',
            onTap: () {
              Navigator.pop(sheet);
              s.scene.play();
              unawaited(s._act(() => s.service.play(home.pet.id)));
            },
          ),
          const SizedBox(height: 10),
          _GameCard(
            key: const ValueKey('game-catchTreats'),
            icon: Icons.restaurant_rounded,
            title: PetGame.catchTreats.title,
            subtitle: PetGame.catchTreats.description,
            onTap: () => start(PetGame.catchTreats),
          ),
          const SizedBox(height: 10),
          _GameCard(
            key: const ValueKey('game-memory'),
            icon: Icons.grid_view_rounded,
            title: PetGame.memory.title,
            subtitle: PetGame.memory.description,
            onTap: () => start(PetGame.memory),
          ),
        ],
      );
    },
  );
}

/// The end of a finished round (a quit round pays nothing).
class _GameResult {
  final int score;
  const _GameResult(this.score);
}

Future<void> _playGame(
  BuildContext context,
  _HomeState home,
  PetGame game,
) async {
  final s = home.s, pet = home.pet;
  final species = PetSpecies.byId(pet.species) ?? PetSpecies.fox;
  final result = await Navigator.of(context).push<_GameResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => Theme(
        data: PetsLook.theme(context),
        child: switch (game) {
          PetGame.catchTreats => _CatchGame(species: species),
          PetGame.memory => const _MemoryGame(),
        },
      ),
    ),
  );
  if (result == null) return;
  final coins = await s._act(
    () => s.service.finishGame(game, result.score, petId: pet.id),
  );
  if (coins == null) return;
  s.scene.cheer();
  final limit = (s.overview.value?.gameCoinsToday ?? 0) >= PetGames.dailyCoins;
  s._say(
    coins > 0
        ? '${pet.name} доволен! +$coins монет'
        : limit
        ? '${pet.name} доволен! Монеты за игры на сегодня уже собраны'
        : '${pet.name} доволен! В этот раз без монет',
  );
}

class _GameCard extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _GameCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: PetsLook.card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: PetsLook.line, width: 1.5),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: PetsLook.lavenderSoft,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(icon, color: PetsLook.deep),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: PetsLook.title(17)),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: PetsLook.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: PetsLook.deep),
          ],
        ),
      ),
    ),
  );
}

/// The frame of a mini-game page: title, score, a close button and the end
/// card. [ended] shows the result and a button that returns it.
class _GamePage extends StatelessWidget {
  final String title, status;
  final Widget child;
  final _GameResult? ended;
  final String endText;
  const _GamePage({
    required this.title,
    required this.status,
    required this.child,
    this.ended,
    this.endText = '',
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: PetsLook.cream,
    appBar: AppBar(
      backgroundColor: PetsLook.cream,
      title: Text(title, style: PetsLook.title(20)),
      leading: IconButton(
        tooltip: 'Выйти без награды',
        icon: const Icon(Icons.close_rounded, color: PetsLook.deep),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Text(
              status,
              key: const ValueKey('game-status'),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: PetsLook.ink,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (ended != null)
          ColoredBox(
            color: const Color(0x66201420),
            child: Center(
              child: Container(
                margin: const EdgeInsets.all(28),
                padding: const EdgeInsets.all(22),
                decoration: PetsLook.panel(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Готово!', style: PetsLook.title(26)),
                    const SizedBox(height: 8),
                    Text(
                      endText,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: PetsLook.ink,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const ValueKey('game-finish'),
                      style: FilledButton.styleFrom(
                        backgroundColor: PetsLook.lavender,
                        minimumSize: const Size(200, 48),
                      ),
                      onPressed: () => Navigator.pop(context, ended),
                      child: const Text('Забрать награду'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------- catch

/// «Поймай угощение»: treats fall, the pet at the bottom follows a drag (or
/// the arrow keys). Treats give points, thorns take two away.
class _CatchGame extends StatefulWidget {
  final PetSpecies species;
  const _CatchGame({required this.species});
  @override
  State<_CatchGame> createState() => _CatchGameState();
}

class _Falling {
  final String? icon; // null: a thorn
  final int points;
  double x, y; // 0..1 of the field
  final double speed; // field heights per second
  _Falling(this.icon, this.points, this.x, this.y, this.speed);
}

class _CatchGameState extends State<_CatchGame>
    with SingleTickerProviderStateMixin {
  static const _treats = [
    ('assets/pets/icons/food_kibble.png', 1),
    ('assets/pets/icons/food_fish.png', 1),
    ('assets/pets/icons/food_berries.png', 1),
    ('assets/pets/icons/food_cake.png', 2),
  ];
  final random = math.Random();
  late final Ticker ticker = createTicker(_tick);
  final items = <_Falling>[];
  double player = .5, elapsed = 0, _last = 0, _spawn = 0;
  int score = 0, caught = 0;
  _GameResult? ended;

  @override
  void initState() {
    super.initState();
    ticker.start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  double get left => math.max(0, PetGames.catchSeconds - elapsed);

  void _tick(Duration now) {
    final t = now.inMicroseconds / 1e6;
    final dt = math.min(0.05, t - _last);
    _last = t;
    if (ended != null) return;
    elapsed += dt;
    // Faster and denser towards the end.
    final pace = 1 + elapsed / PetGames.catchSeconds;
    _spawn -= dt;
    if (_spawn <= 0) {
      _spawn = (0.75 - 0.25 * (pace - 1)) * (0.7 + random.nextDouble() * 0.6);
      final thorn = random.nextDouble() < 0.22;
      final treat = _treats[random.nextInt(_treats.length)];
      items.add(
        _Falling(
          thorn ? null : treat.$1,
          thorn ? -2 : treat.$2,
          0.08 + random.nextDouble() * 0.84,
          -0.1,
          (0.28 + random.nextDouble() * 0.12) * pace,
        ),
      );
    }
    for (final f in [...items]) {
      f.y += f.speed * dt;
      // The pet catches what reaches its band near the bottom.
      if (f.y > 0.8 && f.y < 0.92 && (f.x - player).abs() < 0.12) {
        items.remove(f);
        score = math.max(0, score + f.points);
        if (f.points > 0) caught++;
      } else if (f.y > 1.1) {
        items.remove(f);
      }
    }
    if (elapsed >= PetGames.catchSeconds) {
      items.clear();
      ended = _GameResult(score);
    }
    setState(() {});
  }

  void _move(double to) => setState(() => player = to.clamp(0.06, 0.94));

  @override
  Widget build(BuildContext context) => _GamePage(
    title: PetGame.catchTreats.title,
    status: '★ $score · ${left.ceil()} с',
    ended: ended,
    endText:
        'Поймано угощений: $caught, очков: $score.\n'
        'Награда: до ${PetGames.catchCoins(score)} монет.',
    child: Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _move(player - 0.06);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _move(player + 0.06);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth, h = c.maxHeight;
          final size = math.min(64.0, w * .14);
          return GestureDetector(
            key: const ValueKey('catch-field'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => _move(player + d.delta.dx / w),
            onTapDown: (d) => _move(d.localPosition.dx / w),
            child: Stack(
              children: [
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFFF1E8F8), Color(0xFFFBF4E8)],
                      ),
                    ),
                  ),
                ),
                for (final f in items)
                  Positioned(
                    left: f.x * w - size / 2,
                    top: f.y * h - size / 2,
                    width: size,
                    height: size,
                    child: f.icon == null
                        ? const CustomPaint(painter: _ThornPainter())
                        : Image.asset(
                            f.icon!,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.cookie_outlined,
                              color: PetsLook.food,
                            ),
                          ),
                  ),
                Positioned(
                  left: player * w - size * .9,
                  top: h * .86 - size * .9,
                  width: size * 1.8,
                  height: size * 1.8,
                  child: Image.asset(
                    widget.species.icon,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.pets, color: PetsLook.deep, size: 48),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// A dark green spiky ball: the thing not to catch.
class _ThornPainter extends CustomPainter {
  const _ThornPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final path = Path();
    for (var i = 0; i < 16; i++) {
      final a = i * math.pi / 8;
      final rr = i.isEven ? r : r * .55;
      final p = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF55703F));
    canvas.drawCircle(c, r * .38, Paint()..color = const Color(0xFF3E5530));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------- memory

/// «Найди пару»: twelve cards with shop pictures, six pairs. A move is two
/// cards turned; fewer moves pay more.
class _MemoryGame extends StatefulWidget {
  const _MemoryGame();
  @override
  State<_MemoryGame> createState() => _MemoryGameState();
}

class _MemoryGameState extends State<_MemoryGame> {
  static const _pictures = [
    'food_kibble',
    'food_fish',
    'food_berries',
    'food_cake',
    'acc_scarf',
    'acc_beanie',
    'decor_globe',
    'decor_lantern',
    'decor_aquarium',
    'decor_moon_lamp',
  ];
  late final List<String> cards = () {
    final r = math.Random();
    final picked = [..._pictures]..shuffle(r);
    return [
      for (final id in picked.take(PetGames.memoryPairs)) ...[id, id],
    ]..shuffle(r);
  }();
  final open = <int>{}, done = <int>{};
  int moves = 0;
  bool waiting = false;

  bool get cleared => done.length == cards.length;

  Future<void> _tap(int i) async {
    if (waiting || open.contains(i) || done.contains(i) || cleared) return;
    setState(() => open.add(i));
    if (open.length < 2) return;
    moves++;
    final [a, b] = open.toList();
    if (cards[a] == cards[b]) {
      setState(() {
        done.addAll(open);
        open.clear();
      });
      return;
    }
    waiting = true;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() {
      open.clear();
      waiting = false;
    });
  }

  @override
  Widget build(BuildContext context) => _GamePage(
    title: PetGame.memory.title,
    status: 'Ходов: $moves',
    ended: cleared ? _GameResult(moves) : null,
    endText:
        'Все пары за $moves ходов.\n'
        'Награда: до ${PetGames.memoryCoins(moves, cleared: true)} монет.',
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          shrinkWrap: true,
          children: [
            for (var i = 0; i < cards.length; i++)
              _MemoryCard(
                key: ValueKey('card-$i'),
                picture: 'assets/pets/icons/${cards[i]}.png',
                face: open.contains(i) || done.contains(i),
                done: done.contains(i),
                onTap: () => _tap(i),
              ),
          ],
        ),
      ),
    ),
  );
}

class _MemoryCard extends StatelessWidget {
  final String picture;
  final bool face, done;
  final VoidCallback onTap;
  const _MemoryCard({
    super.key,
    required this.picture,
    required this.face,
    required this.done,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    decoration: BoxDecoration(
      color: face ? PetsLook.card : PetsLook.lavender,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: done ? PetsLook.joy : PetsLook.line,
        width: done ? 3 : 1.5,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33281A28),
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: face
              ? Image.asset(
                  picture,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.image_outlined, color: PetsLook.deep),
                )
              : const Icon(Icons.pets, color: Colors.white, size: 34),
        ),
      ),
    ),
  );
}
