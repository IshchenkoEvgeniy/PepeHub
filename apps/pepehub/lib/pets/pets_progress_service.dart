part of 'pets_service.dart';

/// Buying pets, mini-game rewards and achievements.
extension PetsProgress on PetsService {
  // ---------------------------------------------------------------- pets

  /// Species the shop sells: every one not owned yet (one pet per species).
  List<PetSpecies> petOffers(List<Pet> pets) => [
    for (final s in PetSpecies.values)
      if (!pets.any((p) => p.species == s.name)) s,
  ];

  /// Buys a pet of [species] for [petPrice]: it arrives at once, fed.
  Future<String> buyPet(PetSpecies species) => _db.transaction(() async {
    if (await enabledAt() == null) {
      throw const PetsActionError('Питомник ещё не начат');
    }
    if (!petOffers(await pets()).contains(species)) {
      throw const PetsActionError('Такой питомец уже живёт дома');
    }
    if (await balance() < petPrice) {
      throw const PetsActionError('Не хватает монет');
    }
    final id = await createPet(species.name, species.label);
    await _grant(
      day: petDay(clock()),
      kind: 'pet',
      coins: -petPrice,
      ref: id,
      note: 'Новый питомец: ${species.label}',
      dedup: 'pet:${species.name}',
    );
    await _checkProgress();
    return id;
  });

  // ---------------------------------------------------------- mini-games

  /// Coins won in mini-games today.
  Future<int> gameCoinsToday() async =>
      (await _db
              .customSelect(
                "SELECT COALESCE(SUM(coins),0) AS s FROM pets_ledger_v1 WHERE kind='game' AND day=?",
                variables: [Variable(petDay(clock()))],
              )
              .getSingle())
          .read<int>('s');

  /// Records a finished round: pays its coins within today's limit and
  /// cheers [petId] up. Returns the coins paid (0 once the limit is reached).
  Future<int> finishGame(
    PetGame game,
    int score, {
    required String petId,
    bool cleared = true,
  }) async {
    final paid = await _db.transaction(() async {
      final coins = PetGames.payable(
        PetGames.coins(game, score, cleared: cleared),
        await gameCoinsToday(),
      );
      if (coins > 0) {
        await _grant(
          day: petDay(clock()),
          kind: 'game',
          coins: coins,
          ref: game.name,
          note: 'Мини-игра «${game.title}»',
          dedup: 'game:${const Uuid().v4()}',
        );
        await _checkProgress();
      }
      return coins;
    });
    await cheer(petId, PetRules.moodPlay);
    return paid;
  }

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
          "(SELECT COALESCE(SUM(coins),0) FROM pets_ledger_v1 WHERE kind='game') AS games",
        )
        .getSingle();
    final enabled = await enabledAt();
    return AchievementProgress(
      books: row.read<int>('books'),
      minutes: row.read<int>('minutes'),
      gameCoins: row.read<int>('games'),
      pets: all.length,
      bestStreak: enabled == null ? 0 : (await _replay(enabled)).best,
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
