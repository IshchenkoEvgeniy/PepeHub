part of 'pets_service.dart';

/// An egg in the incubator.
class PetEgg {
  final String id, species;

  /// A copy of an owned species: hatches into the reserve.
  final bool copy;

  /// Credited minutes needed and gathered so far.
  final int minutes, progress;
  final DateTime createdAt;
  const PetEgg({
    required this.id,
    required this.species,
    required this.copy,
    required this.minutes,
    required this.progress,
    required this.createdAt,
  });
  bool get ready => progress >= minutes;
  double get fraction => minutes == 0 ? 1 : (progress / minutes).clamp(0, 1);
}

/// An egg the shop can sell right now.
class PetEggOffer {
  final PetSpecies species;
  final bool copy;
  const PetEggOffer(this.species, {required this.copy});
  int get price => copy ? copyEggPrice : speciesEggPrice;
  int get minutes => copy ? copyEggMinutes : speciesEggMinutes;
}

Set<String> _talents(String raw) {
  try {
    final value = jsonDecode(raw);
    return value is List ? {...value.whereType<String>()} : {};
  } on FormatException {
    return {};
  }
}

/// Stage 4: incubator, growth paths, talents, merging and achievements.
extension PetsProgress on PetsService {
  // ---------------------------------------------------------------- eggs

  Future<int> incubatorSlots() async =>
      (await owned()).contains(incubatorSlotId) ? 2 : 1;

  Future<List<PetEgg>> eggs() async {
    final rows = await _db
        .customSelect(
          'SELECT e.*,(SELECT COALESCE(SUM(l.coins),0) FROM pets_ledger_v1 l '
          "WHERE l.kind='time' AND l.id>e.start_ledger) AS progress "
          'FROM pets_eggs_v1 e WHERE e.hatched_at IS NULL ORDER BY e.created_at',
        )
        .get();
    return [
      for (final r in rows)
        PetEgg(
          id: r.read<String>('id'),
          species: r.read<String>('species'),
          copy: r.read<int>('copy') != 0,
          minutes: r.read<int>('minutes'),
          progress: r.read<int>('progress'),
          createdAt: DateTime.parse(r.read<String>('created_at')).toLocal(),
        ),
    ];
  }

  Future<Map<String, int>> reserve() async => {
    for (final r
        in await _db
            .customSelect(
              'SELECT species,count FROM pets_reserve_v1 WHERE count>0',
            )
            .get())
      r.read<String>('species'): r.read<int>('count'),
  };

  /// A species not owned yet sells as a new pet (one egg at a time); an
  /// owned one, unless unique, sells as a copy for the reserve.
  List<PetEggOffer> eggOffers(List<Pet> pets, List<PetEgg> eggs) {
    final offers = <PetEggOffer>[];
    for (final s in PetSpecies.values) {
      final mine = pets.where((p) => p.species == s.name);
      if (mine.isNotEmpty) {
        if (!mine.any((p) => p.unique)) offers.add(PetEggOffer(s, copy: true));
      } else if (!eggs.any((e) => e.species == s.name && !e.copy)) {
        offers.add(PetEggOffer(s, copy: false));
      }
    }
    return offers;
  }

  Future<void> buyEgg(PetSpecies species) => _db.transaction(() async {
    if (await enabledAt() == null) {
      throw const PetsActionError('Питомник ещё не начат');
    }
    final all = await pets(), waiting = await eggs();
    final offer = eggOffers(
      all,
      waiting,
    ).where((o) => o.species == species).firstOrNull;
    if (offer == null) throw const PetsActionError('Это яйцо сейчас не купить');
    if (waiting.length >= await incubatorSlots()) {
      throw const PetsActionError('Инкубатор занят');
    }
    if (await balance() < offer.price) {
      throw const PetsActionError('Не хватает монет');
    }
    final now = clock();
    final last =
        (await _db
                .customSelect(
                  'SELECT COALESCE(MAX(id),0) AS id FROM pets_ledger_v1',
                )
                .getSingle())
            .read<int>('id');
    final id = const Uuid().v4();
    await _grant(
      day: petDay(now),
      kind: 'egg',
      coins: -offer.price,
      ref: id,
      note:
          'Покупка: яйцо ${offer.copy ? 'копии ' : ''}'
          '(${species.label.toLowerCase()})',
      dedup: 'egg:$id',
    );
    await _db.customStatement(
      'INSERT INTO pets_eggs_v1(id,species,copy,minutes,start_ledger,created_at) '
      'VALUES(?,?,?,?,?,?)',
      [
        id,
        species.name,
        offer.copy ? 1 : 0,
        offer.minutes,
        last,
        now.toUtc().toIso8601String(),
      ],
    );
  });

  /// A ready egg hatches: a new species becomes a pet, a copy goes to the
  /// reserve. Returns the new pet id, or null for a copy.
  Future<String?> hatch(String eggId) => _db.transaction(() async {
    final egg = (await eggs()).where((e) => e.id == eggId).firstOrNull;
    if (egg == null) throw const PetsActionError('Яйцо не найдено');
    if (!egg.ready) throw const PetsActionError('Яйцо ещё не готово');
    final species = PetSpecies.byId(egg.species);
    final now = clock();
    await _db.customStatement(
      'UPDATE pets_eggs_v1 SET hatched_at=? WHERE id=?',
      [now.toUtc().toIso8601String(), eggId],
    );
    String? petId;
    final copy =
        egg.copy || (await pets()).any((p) => p.species == egg.species);
    if (copy) {
      await _db.customStatement(
        'INSERT INTO pets_reserve_v1(species,count) VALUES(?,1) '
        'ON CONFLICT(species) DO UPDATE SET count=count+1',
        [egg.species],
      );
    } else {
      petId = await createPet(egg.species, species?.label ?? egg.species);
    }
    await _grant(
      day: petDay(now),
      kind: 'hatch',
      ref: eggId,
      note: copy
          ? 'Из яйца вылупилась копия: ${species?.label ?? egg.species}'
          : 'Из яйца вылупился новый питомец: ${species?.label ?? egg.species}',
      dedup: 'hatch:$eggId',
    );
    await _checkProgress();
    return petId;
  });

  // ---------------------------------------------------------- path, talents

  Future<Pet> _pet(String petId) async {
    final pet = (await pets()).where((p) => p.id == petId).firstOrNull;
    if (pet == null) throw const PetsActionError('Питомец не найден');
    return pet;
  }

  /// Once, from level 25; the adult model follows the path.
  Future<void> choosePath(String petId, PetPath path) =>
      _db.transaction(() async {
        final pet = await _pet(petId);
        if (pet.path != null) throw const PetsActionError('Путь уже выбран');
        if (pet.level < PetRules.pathLevel) {
          throw PetsActionError(
            'Путь выбирается с ${PetRules.pathLevel}-го уровня',
          );
        }
        if (path.species.name != pet.species) {
          throw const PetsActionError('Этот путь для другого вида');
        }
        await _db.customStatement('UPDATE pets_v1 SET path=? WHERE id=?', [
          path.name,
          petId,
        ]);
        await _grant(
          day: petDay(clock()),
          kind: 'path',
          ref: petId,
          note: '${pet.name} выбирает путь: ${path.label}',
          dedup: 'path:$petId',
        );
      });

  Future<void> learnTalent(String petId, String talentId) =>
      _db.transaction(() async {
        final talent = petTalent(talentId);
        if (talent == null) throw const PetsActionError('Такого таланта нет');
        final pet = await _pet(petId);
        if (pet.talents.contains(talentId)) {
          throw const PetsActionError('Талант уже изучен');
        }
        if (pet.level < talent.minLevel) {
          throw PetsActionError('Нужен ${talent.minLevel}-й уровень');
        }
        if (pet.talentPointsFree < talent.cost) {
          throw const PetsActionError('Не хватает очков таланта');
        }
        await _setTalents(petId, {...pet.talents, talentId});
      });

  /// Returns every point for [talentResetPrice] coins.
  Future<void> resetTalents(String petId) => _db.transaction(() async {
    final pet = await _pet(petId);
    if (pet.talents.isEmpty) throw const PetsActionError('Нечего сбрасывать');
    if (await balance() < talentResetPrice) {
      throw const PetsActionError('Не хватает монет');
    }
    await _grant(
      day: petDay(clock()),
      kind: 'talent-reset',
      coins: -talentResetPrice,
      ref: petId,
      note: 'Сброс талантов: ${pet.name}',
      dedup: 'talent-reset:${const Uuid().v4()}',
    );
    await _setTalents(petId, {});
    // Accessories beyond the slots left come off.
    final slots = PetGrowth.accessorySlots(pet.level, pet.rank, const {});
    if (pet.accessories.length > slots) {
      final kept = Map.fromEntries(pet.accessories.entries.take(slots));
      await _db.customStatement('UPDATE pets_v1 SET accessories=? WHERE id=?', [
        jsonEncode({for (final e in kept.entries) e.key.name: e.value}),
        petId,
      ]);
    }
  });

  Future<void> _setTalents(String petId, Set<String> talents) =>
      _db.customStatement('UPDATE pets_v1 SET talents=? WHERE id=?', [
        jsonEncode(talents.toList()..sort()),
        petId,
      ]);

  // ---------------------------------------------------------------- merge

  /// The next rank step of [pet], or null at ★★★ or for a unique pet.
  RankStep? nextRank(Pet pet) =>
      pet.unique || pet.rank >= rankSteps.length ? null : rankSteps[pet.rank];

  /// Merges copies from the reserve into [petId] for the next star. The
  /// pet keeps its level, experience, name, path and history.
  Future<void> merge(String petId) => _db.transaction(() async {
    final pet = await _pet(petId);
    final step = nextRank(pet);
    if (step == null) throw const PetsActionError('Объединять больше нельзя');
    if (pet.level < step.level) {
      throw PetsActionError('Нужен ${step.level}-й уровень');
    }
    final copies = (await reserve())[pet.species] ?? 0;
    if (copies < step.copies) {
      throw PetsActionError('Нужно копий в запасе: ${step.copies}');
    }
    if (await balance() < step.fee) {
      throw const PetsActionError('Не хватает монет');
    }
    await _grant(
      day: petDay(clock()),
      kind: 'merge',
      coins: -step.fee,
      ref: petId,
      note: 'Объединение: ${pet.name} получает ${step.label}',
      dedup: 'merge:$petId:${pet.rank + 1}',
    );
    await _db.customStatement(
      'UPDATE pets_reserve_v1 SET count=count-? WHERE species=?',
      [step.copies, pet.species],
    );
    await _db.customStatement('UPDATE pets_v1 SET rank=? WHERE id=?', [
      pet.rank + 1,
      petId,
    ]);
    await _checkProgress();
  });

  // --------------------------------------------------------- achievements

  Future<Set<String>> unlockedAchievements() async => {
    for (final r
        in await _db
            .customSelect(
              "SELECT ref FROM pets_ledger_v1 WHERE kind='achievement'",
            )
            .get())
      ?r.readNullable<String>('ref'),
  };

  /// Shows an unlocked achievement's title in the profile; null hides it.
  Future<void> setHonor(String? achievementId) async {
    if (achievementId == null) {
      await _db.customStatement('DELETE FROM metadata WHERE key=?', [
        PetsService._honorKey,
      ]);
      return;
    }
    final a = petAchievement(achievementId);
    if (a?.honor == null ||
        !(await unlockedAchievements()).contains(achievementId)) {
      throw const PetsActionError('Титул ещё не получен');
    }
    await repository.setMeta(PetsService._honorKey, achievementId);
  }

  Future<AchievementProgress> _progress(List<Pet> all) async {
    final row = await _db
        .customSelect(
          "SELECT (SELECT COUNT(*) FROM pets_ledger_v1 WHERE kind='book') AS books,"
          "(SELECT COALESCE(SUM(coins),0) FROM pets_ledger_v1 WHERE kind='time') AS minutes,"
          '(SELECT COUNT(*) FROM pets_eggs_v1 WHERE hatched_at IS NOT NULL) AS hatched',
        )
        .getSingle();
    final enabled = await enabledAt();
    return AchievementProgress(
      books: row.read<int>('books'),
      minutes: row.read<int>('minutes'),
      hatched: row.read<int>('hatched'),
      bestStreak: enabled == null ? 0 : (await _replay(enabled)).best,
      maxRank: all.fold(0, (a, p) => math.max(a, p.rank)),
      maxLevel: all.fold(1, (a, p) => math.max(a, p.level)),
    );
  }

  /// Grants round-level rewards and reached achievements. Idempotent:
  /// every grant has its own dedup key.
  Future<void> _checkProgress() async {
    final all = await pets();
    final day = petDay(clock());
    for (final pet in all) {
      for (var l = 10; l <= pet.level; l += 10) {
        await _grant(
          day: day,
          kind: 'level',
          coins: PetGrowth.levelReward(l),
          ref: pet.id,
          note: '${pet.name}: $l-й уровень',
          dedup: 'level:${pet.id}:$l',
        );
      }
    }
    final progress = await _progress(all);
    for (final a in petAchievements) {
      if (!progress.reached(a)) continue;
      final granted = await _grant(
        day: day,
        kind: 'achievement',
        coins: a.coins,
        ref: a.id,
        note: 'Достижение: ${a.title}',
        dedup: 'ach:${a.id}',
      );
      if (granted && a.item != null) {
        await _db.customStatement(
          'INSERT OR IGNORE INTO pets_owned_v1(item_id,bought_at) VALUES(?,?)',
          [a.item, clock().toUtc().toIso8601String()],
        );
      }
    }
  }
}
