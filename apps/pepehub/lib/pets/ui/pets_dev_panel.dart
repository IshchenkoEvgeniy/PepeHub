part of 'pets_section.dart';

/// Developer panel: coins, reading minutes, experience, the game clock,
/// needs and items for checking the section by hand. Shown when the
/// panel is enabled in Settings → Diagnostics (always in debug builds).
/// Everything is ordinary game data; the library and reading statistics are
/// never touched.
Future<void> _showDevPanel(BuildContext context, _PetsSectionState s) => _sheet(
  context,
  s,
  title: 'Панель разработчика',
  builder: (context, o) => _DevPanel(s: s, o: o),
);

class _DevPanel extends StatelessWidget {
  final _PetsSectionState s;
  final PetsOverview o;
  const _DevPanel({required this.s, required this.o});

  @override
  Widget build(BuildContext context) {
    final pet = o.companion!;
    final now = s.now;
    String two(int v) => v.toString().padLeft(2, '0');
    Future<void> run(String done, Future<void> Function() action) async {
      final ok = await s._act(() async {
        await action();
        return true;
      });
      if (ok == true) s._say(done);
    }

    Widget group(String title, String? hint, List<Widget> buttons) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: PetsLook.title(16)),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint,
                style: const TextStyle(color: PetsLook.muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: buttons),
        ],
      ),
    );
    Widget b(String label, VoidCallback? onTap, {Key? key}) =>
        FilledButton.tonal(
          key: key,
          onPressed: s.busy ? null : onTap,
          child: Text(label),
        );
    // Shift that puts the game clock at [hour]:[minute] today.
    int shiftTo(int hour, int minute) {
      final real = (s.widget.clock ?? DateTime.now)();
      final target = DateTime(real.year, real.month, real.day, hour, minute);
      return target.difference(real).inMinutes;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: PetsLook.lavenderSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            'Время игры: ${two(now.hour)}:${two(now.minute)} ${now.day}.${two(now.month)}'
            '${s._shift == 0 ? '' : ' (сдвиг ${s._shift >= 0 ? '+' : ''}${(s._shift / 60).toStringAsFixed(1)} ч)'}\n'
            '${pet.name}: ур. ${pet.level}, опыт ${pet.xp.floor()}, '
            'сытость ${(pet.satiety(now) * 100).round()}%, настроение ${(o.moodOf(pet) * 100).round()}%, '
            'бодрость ${(PetRules.energy(now, lightsOff: o.lightsOff, lightsUntil: o.lightsUntil) * 100).round()}%',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: PetsLook.ink,
            ),
          ),
        ),
        group('Монеты', 'Запись «dev» в журнале; баланс не уходит ниже нуля.', [
          for (final n in [100, 1000, 10000])
            b(
              '+$n',
              () => run('+$n монет', () => s.service.devCoins(n)),
              key: ValueKey('dev-coins-$n'),
            ),
          b('−500', () => run('−500 монет', () => s.service.devCoins(-500))),
        ]),
        group(
          'Чтение сегодня',
          'Как настоящие минуты: монеты, опыт, яйца и серия. Лимит 4 ч в день.',
          [
            for (final n in [15, 60, 240])
              b(
                '+$n мин',
                () => run('+$n мин чтения', () => s.service.devMinutes(n)),
                key: ValueKey('dev-minutes-$n'),
              ),
          ],
        ),
        group('Опыт и уровень компаньона', null, [
          for (final n in [100, 1000])
            b('+$n опыта', () => run('+$n опыта', () => s.service.devXp(n))),
          for (final l in [10, 25, 45, 70, 90, 100])
            b(
              'Ур. $l',
              pet.level >= l
                  ? null
                  : () => run('Уровень $l', () => s.service.devLevel(l)),
            ),
        ]),
        group(
          'Время игры',
          'Сдвигает часы Питомника: сон, сытость, настроение, серия дней.',
          [
            b('−1 ч', () => s.setShift(s._shift - 60)),
            b('+1 ч', () => s.setShift(s._shift + 60)),
            b('+6 ч', () => s.setShift(s._shift + 360)),
            b('+1 день', () => s.setShift(s._shift + 1440)),
            b('Утро 8:00', () => s.setShift(shiftTo(8, 0))),
            b('Вечер 20:00', () => s.setShift(shiftTo(20, 0))),
            b('Ночь 23:30', () => s.setShift(shiftTo(23, 30))),
            b(
              'Реальное время',
              () => s.setShift(0),
              key: const ValueKey('dev-clock-reset'),
            ),
          ],
        ),
        group('Потребности', null, [
          b('Голоден', () => run('Сытость 0%', () => s.service.devSatiety(0))),
          b(
            'Сытость 50%',
            () => run('Сытость 50%', () => s.service.devSatiety(.5)),
          ),
          b('Сыт', () => run('Сытость 100%', () => s.service.devSatiety(1))),
          b(
            'Грустит',
            () => run('Настроение 5%', () => s.service.devMood(.05)),
          ),
          b(
            'Настроение 100%',
            () => run('Настроение 100%', () => s.service.devMood(1)),
          ),
        ]),
        group('Предметы', null, [
          b(
            'Все предметы',
            () => run('Все предметы открыты', s.service.devUnlockItems),
            key: const ValueKey('dev-items'),
          ),
          b(
            'Показать «Пока вас не было»',
            () => run('Окно наград покажется снова', s.service.devReplayUnseen),
          ),
        ]),
        group('Анимации', null, [
          for (final (label, call) in [
            ('Помахать', s.scene.wave),
            ('Радость', s.scene.cheer),
            ('Игра', s.scene.play),
            ('Погладить', s.scene.stroke),
            ('Еда', () => s.scene.eat(treat: true)),
          ])
            b(label, call),
        ]),
        group(
          'Сброс',
          'Стирает монеты, питомцев, яйца и журнал Питомника. Библиотека не затрагивается.',
          [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFC0485E),
              ),
              onPressed: s.busy
                  ? null
                  : () async {
                      final yes = await _confirm(
                        context,
                        'Сбросить Питомник?',
                        'Все игровые данные будут удалены.',
                        'Сбросить',
                      );
                      if (!yes) return;
                      if (context.mounted) Navigator.pop(context);
                      await s._act(s.service.resetAll);
                    },
              child: const Text('Сбросить Питомник'),
            ),
          ],
        ),
      ],
    );
  }
}
