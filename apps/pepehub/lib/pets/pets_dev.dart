part of 'pets_service.dart';

/// Developer tools of the pets section: grant coins, experience and minutes,
/// shift the game clock, set needs. Everything is written as
/// ordinary game data (ledger kind `dev`), never into reading statistics or
/// the library. The panel is enabled in Settings → Diagnostics.
extension PetsDev on PetsService {
  /// Settings flag (outside `pets:` so a game reset keeps the panel).
  static const enabledKey = 'pets-dev-panel';

  /// Shift of the game clock in minutes (outside `pets:` as well).
  static const clockShiftKey = 'pets-dev-clock-shift';

  Future<bool> devEnabled() async => await repository.meta(enabledKey) == '1';

  Future<void> setDevEnabled(bool on) =>
      repository.setMeta(enabledKey, on ? '1' : '0');

  Future<int> devClockShift() async =>
      int.tryParse(await repository.meta(clockShiftKey) ?? '') ?? 0;

  Future<void> setDevClockShift(int minutes) =>
      repository.setMeta(clockShiftKey, '$minutes');

  /// Coins (negative takes them away, never below zero).
  Future<void> devCoins(int amount) => _db.transaction(() async {
    final have = await balance();
    final delta = amount < 0 ? -math.min(-amount, have) : amount;
    if (delta == 0) return;
    await _grant(
      day: petDay(clock()),
      kind: 'dev',
      coins: delta,
      note: 'Панель разработчика: ${delta > 0 ? '+' : ''}$delta монет',
      dedup: 'dev:${const Uuid().v4()}',
    );
  });

  /// Experience for one pet (the companion by default), without coins.
  Future<void> devXp(int amount, {String? petId}) => _db.transaction(() async {
    final id = petId ?? await companionId();
    if (id == null || amount <= 0) return;
    final ledger = await _db.customInsert(
      'INSERT INTO pets_ledger_v1(at,day,kind,coins,xp,ref,note,dedup) VALUES(?,?,?,?,?,?,?,?)',
      variables: [
        Variable(clock().toUtc().toIso8601String()),
        Variable(petDay(clock())),
        Variable('dev'),
        Variable(0),
        Variable(0),
        Variable(id),
        Variable('Панель разработчика: +$amount опыта'),
        Variable('dev:${const Uuid().v4()}'),
      ],
    );
    await _db.customStatement(
      'INSERT INTO pets_xp_v1(ledger_id,pet_id,xp) VALUES(?,?,?)',
      [ledger, id, amount * 1.0],
    );
    await _checkProgress();
  });

  /// Raises the companion straight to [level].
  Future<void> devLevel(int level) async {
    final id = await companionId();
    final pet = (await pets()).where((p) => p.id == id).firstOrNull;
    if (pet == null) return;
    final need =
        PetRules.totalXpForLevel(level.clamp(1, PetRules.maxLevel)) -
        pet.xp.floor();
    if (need > 0) await devXp(need, petId: pet.id);
  }

  /// Reading minutes for today (test minutes, recounted like real reading:
  /// coins, experience and the streak follow).
  Future<void> devMinutes(int minutes) async {
    await addTestMinutes(minutes);
    await sync();
  }

  /// Satiety of every pet: 1 full, 0 hungry.
  Future<void> devSatiety(double value) async {
    final now = clock();
    final fedAt = now.subtract(
      Duration(
        minutes: ((1 - value.clamp(0, 1)) * PetRules.fullHours * 60).round(),
      ),
    );
    await _db.customStatement('UPDATE pets_v1 SET fed_at=?', [
      fedAt.toUtc().toIso8601String(),
    ]);
  }

  /// Mood of the companion.
  Future<void> devMood(double value) async {
    final id = await companionId();
    if (id == null) return;
    final now = clock();
    final raw = await _moodRaw();
    raw[id] = (value.clamp(0.0, 1.0), now);
    await repository.setMeta(
      PetsService._moodKey,
      jsonEncode({
        for (final e in raw.entries)
          e.key: {'v': e.value.$1, 'at': e.value.$2.toUtc().toIso8601String()},
      }),
    );
  }

  /// Every item of the shop and every reward item owned, five portions of food.
  Future<void> devUnlockItems() => _db.transaction(() async {
    final now = clock().toUtc().toIso8601String();
    for (final item in shopItems) {
      if (item.kind == ShopKind.food) {
        await _db.customStatement(
          'INSERT INTO pets_inventory_v1(item_id,count) VALUES(?,5) '
          'ON CONFLICT(item_id) DO UPDATE SET count=count+5',
          [item.id],
        );
      } else if (!item.kind.consumable) {
        await _db.customStatement(
          'INSERT OR IGNORE INTO pets_owned_v1(item_id,bought_at) VALUES(?,?)',
          [item.id, now],
        );
      }
    }
  });

  /// Shows the «while you were away» card again for everything granted today.
  Future<void> devReplayUnseen() async {
    final row = await _db
        .customSelect(
          'SELECT COALESCE(MIN(id),1)-1 AS id FROM pets_ledger_v1 WHERE day=?',
          variables: [Variable(petDay(clock()))],
        )
        .getSingle();
    await markSeen(row.read<int>('id'));
  }
}
