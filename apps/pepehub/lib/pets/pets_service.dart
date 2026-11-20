import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../audio/audio_daily_totals.dart';
import '../data/repository.dart';
import '../reader/reading_daily_totals.dart';
import 'pet_catalog.dart';
import 'pet_rules.dart';

/// One row of the coins and experience journal.
class PetLedgerEntry {
  final int id;
  final DateTime at;
  final String day, kind, note;
  final String? ref;
  final int coins, xp;
  const PetLedgerEntry({
    required this.id,
    required this.at,
    required this.day,
    required this.kind,
    required this.coins,
    required this.xp,
    required this.note,
    this.ref,
  });
}

class Pet {
  final String id, species, name;
  final DateTime createdAt;
  final double xp;

  /// Bought color item id, or null for the natural one.
  final String? color;

  /// Accessory item id per socket.
  final Map<PetSocket, String> accessories;
  final DateTime? fedAt;
  const Pet({
    required this.id,
    required this.species,
    required this.name,
    required this.createdAt,
    required this.xp,
    this.color,
    this.accessories = const {},
    this.fedAt,
  });
  int get level => PetRules.levelForXp(xp.floor());
  PetStage get stage => PetRules.stageForLevel(level);

  /// 1 right after a full meal, 0 when hungry (a day without food).
  double satiety(DateTime now) => PetRules.satiety(fedAt, now);
}

/// Snapshot for the pets screen.
class PetsOverview {
  final DateTime? enabledAt;
  final int balance, todayMinutes, todayCredited;
  final StreakState streak;
  final Pet? companion;
  final List<Pet> pets;
  final List<PetLedgerEntry> recent;

  /// Title of today's book bonus, if it was granted.
  final String? bookOfDay;
  final Map<String, int> inventory;
  final Set<String> owned;
  const PetsOverview({
    required this.enabledAt,
    required this.balance,
    required this.todayMinutes,
    required this.todayCredited,
    required this.streak,
    required this.companion,
    required this.pets,
    required this.recent,
    this.bookOfDay,
    this.inventory = const {},
    this.owned = const {},
  });
}

/// A purchase or use that is not allowed; [message] is shown to the user.
class PetsActionError implements Exception {
  final String message;
  const PetsActionError(this.message);
  @override
  String toString() => message;
}

/// Ledger, pets and the idempotent daily recount. Game data stays in the
/// `pets_*` tables and `pets:` metadata; library cards are never touched.
class PetsService {
  final Repository repository;
  final DateTime Function() clock;
  PetsService(this.repository, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  static const _enabledKey = 'pets:enabledAt';
  static const _companionKey = 'pets:companion';
  static const _syncedKey = 'pets:syncedDay';
  static const _testKey = 'pets:testMinutes';

  // ------------------------------------------------------- testing helpers

  /// Test-only minutes added to a day on top of real reading, so limits,
  /// levels and streaks can be tried without touching reading statistics.
  /// They live only in `pets:` metadata and never reach the library journal.
  Future<Map<String, int>> testMinutes() async {
    final raw = await repository.meta(_testKey);
    if (raw == null) return {};
    final value = jsonDecode(raw);
    return value is Map
        ? {for (final e in value.entries) '${e.key}': (e.value as num).toInt()}
        : {};
  }

  Future<void> addTestMinutes(int minutes, {DateTime? day}) async {
    final key = petDay(day ?? clock());
    final all = await testMinutes();
    all[key] = (all[key] ?? 0) + minutes;
    await repository.setMeta(_testKey, jsonEncode(all));
  }

  /// Erases all game data (ledger, pets, days, settings) — not the library.
  Future<void> resetAll() => _db.transaction(() async {
    for (final table in [
      'pets_inventory_v1',
      'pets_owned_v1',
      'pets_xp_v1',
      'pets_ledger_v1',
      'pets_v1',
      'pets_days_v1',
      'pets_finish_queue_v1',
    ]) {
      await _db.customStatement('DELETE FROM $table');
    }
    await _db.customStatement(
      "DELETE FROM metadata WHERE key>='pets:' AND key<'pets;'",
    );
  });

  GeneratedDatabase get _db => repository.db;

  Future<DateTime?> enabledAt() async {
    final raw = await repository.meta(_enabledKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  /// Starts counting from now with the chosen starter as companion.
  /// Past reading grants nothing (no start capital).
  Future<void> enable({PetSpecies species = PetSpecies.cat, String? name}) =>
      _db.transaction(() async {
        if (await enabledAt() != null) return;
        await repository.setMeta(
          _enabledKey,
          clock().toUtc().toIso8601String(),
        );
        final id = await createPet(species.name, name ?? species.label);
        await setCompanion(id);
      });

  /// A new pet arrives fed.
  Future<String> createPet(String species, String name) async {
    final id = const Uuid().v4();
    final now = clock().toUtc().toIso8601String();
    await _db.customStatement(
      'INSERT INTO pets_v1(id,species,name,created_at,fed_at) VALUES(?,?,?,?,?)',
      [id, species, name, now, now],
    );
    return id;
  }

  // ------------------------------------------------------------- shop & care

  Future<Map<String, int>> inventory() async => {
    for (final r
        in await _db
            .customSelect(
              'SELECT item_id,count FROM pets_inventory_v1 WHERE count>0',
            )
            .get())
      r.read<String>('item_id'): r.read<int>('count'),
  };

  Future<Set<String>> owned() async => {
    for (final r
        in await _db.customSelect('SELECT item_id FROM pets_owned_v1').get())
      r.read<String>('item_id'),
  };

  /// Pays for [itemId]. Coins never go below zero; permanent items are
  /// bought once; freezes only while the stock has room.
  Future<void> buy(String itemId) => _db.transaction(() async {
    final item = shopItem(itemId);
    if (item == null) throw const PetsActionError('Такого товара нет');
    if (await enabledAt() == null) {
      throw const PetsActionError('Питомник ещё не начат');
    }
    if (await balance() < item.price) {
      throw const PetsActionError('Не хватает монет');
    }
    if (!item.kind.consumable && (await owned()).contains(itemId)) {
      throw const PetsActionError('Уже куплено');
    }
    if (item.kind == ShopKind.freeze &&
        (await _replay((await enabledAt())!)).freezes >= PetRules.maxFreezes) {
      throw const PetsActionError('В запасе уже две заморозки');
    }
    final now = clock();
    await _grant(
      day: petDay(now),
      kind: item.kind == ShopKind.freeze ? 'freeze-buy' : 'buy',
      coins: -item.price,
      ref: itemId,
      note: 'Покупка: ${item.title}',
      dedup: 'buy:${const Uuid().v4()}',
    );
    if (item.kind == ShopKind.food) {
      await _db.customStatement(
        'INSERT INTO pets_inventory_v1(item_id,count) VALUES(?,1) '
        'ON CONFLICT(item_id) DO UPDATE SET count=count+1',
        [itemId],
      );
    } else if (!item.kind.consumable) {
      await _db.customStatement(
        'INSERT INTO pets_owned_v1(item_id,bought_at) VALUES(?,?)',
        [itemId, now.toUtc().toIso8601String()],
      );
    }
  });

  /// Spends one portion of [foodId] on [petId]. Satiety restores by the
  /// food's hours, never above full.
  Future<ShopItem> feed(String petId, String foodId) =>
      _db.transaction(() async {
        final food = shopItem(foodId);
        if (food == null || food.kind != ShopKind.food) {
          throw const PetsActionError('Это не еда');
        }
        final pet = (await pets()).where((p) => p.id == petId).firstOrNull;
        if (pet == null) throw const PetsActionError('Питомец не найден');
        final left = (await inventory())[foodId] ?? 0;
        if (left <= 0) throw PetsActionError('${food.title} закончился');
        final now = clock();
        await _db.customStatement(
          'UPDATE pets_inventory_v1 SET count=count-1 WHERE item_id=?',
          [foodId],
        );
        await _db.customStatement('UPDATE pets_v1 SET fed_at=? WHERE id=?', [
          PetRules.fedAfter(
            pet.fedAt,
            now,
            food.satietyHours,
          ).toUtc().toIso8601String(),
          petId,
        ]);
        await _grant(
          day: petDay(now),
          kind: 'feed',
          ref: foodId,
          note: '${pet.name}: ${food.title.toLowerCase()}',
          dedup: 'feed:${const Uuid().v4()}',
        );
        return food;
      });

  Future<void> rename(String petId, String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 24) {
      throw const PetsActionError('Имя — от 1 до 24 символов');
    }
    await _db.customStatement('UPDATE pets_v1 SET name=? WHERE id=?', [
      clean,
      petId,
    ]);
  }

  /// [colorId] null returns the natural color.
  Future<void> setColor(String petId, String? colorId) async {
    if (colorId != null && !(await owned()).contains(colorId)) {
      throw const PetsActionError('Окрас не куплен');
    }
    await _db.customStatement('UPDATE pets_v1 SET color=? WHERE id=?', [
      colorId,
      petId,
    ]);
  }

  /// Puts [accessoryId] on its socket, or takes off whatever is on [socket].
  Future<void> setAccessory(
    String petId,
    PetSocket socket,
    String? accessoryId,
  ) => _db.transaction(() async {
    if (accessoryId != null) {
      final item = shopItem(accessoryId);
      if (item?.socket != socket) {
        throw const PetsActionError('Не подходит');
      }
      if (!(await owned()).contains(accessoryId)) {
        throw const PetsActionError('Аксессуар не куплен');
      }
    }
    final pet = (await pets()).firstWhere((p) => p.id == petId);
    final next = {for (final e in pet.accessories.entries) e.key.name: e.value};
    if (accessoryId == null) {
      next.remove(socket.name);
    } else {
      next[socket.name] = accessoryId;
    }
    await _db.customStatement('UPDATE pets_v1 SET accessories=? WHERE id=?', [
      jsonEncode(next),
      petId,
    ]);
  });

  Future<String?> companionId() => repository.meta(_companionKey);
  Future<void> setCompanion(String petId) =>
      repository.setMeta(_companionKey, petId);

  Future<int> balance() async =>
      (await _db
              .customSelect(
                'SELECT COALESCE(SUM(coins),0) AS s FROM pets_ledger_v1',
              )
              .getSingle())
          .read<int>('s');

  Future<List<Pet>> pets() async {
    final rows = await _db
        .customSelect(
          'SELECT p.id,p.species,p.name,p.created_at,p.color,p.accessories,p.fed_at,'
          'COALESCE(SUM(x.xp),0) AS xp '
          'FROM pets_v1 p LEFT JOIN pets_xp_v1 x ON x.pet_id=p.id '
          'GROUP BY p.id ORDER BY p.created_at',
        )
        .get();
    Map<PetSocket, String> sockets(String raw) {
      try {
        final value = jsonDecode(raw);
        if (value is! Map) return {};
        return {
          for (final s in PetSocket.values)
            if (value[s.name] is String) s: value[s.name] as String,
        };
      } on FormatException {
        return {};
      }
    }

    return [
      for (final r in rows)
        Pet(
          id: r.read<String>('id'),
          species: r.read<String>('species'),
          name: r.read<String>('name'),
          createdAt: DateTime.parse(r.read<String>('created_at')).toLocal(),
          xp: r.read<double>('xp'),
          color: r.readNullable<String>('color'),
          accessories: sockets(r.read<String>('accessories')),
          fedAt: DateTime.tryParse(r.readNullable<String>('fed_at') ?? '')
              ?.toLocal(),
        ),
    ];
  }

  /// Newest first; [before] pages by ledger id for a lazy list.
  Future<List<PetLedgerEntry>> ledger({int limit = 50, int? before}) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM pets_ledger_v1 WHERE id<? ORDER BY id DESC LIMIT ?',
          variables: [Variable(before ?? 1 << 62), Variable(limit)],
        )
        .get();
    return [
      for (final r in rows)
        PetLedgerEntry(
          id: r.read<int>('id'),
          at: DateTime.parse(r.read<String>('at')).toLocal(),
          day: r.read<String>('day'),
          kind: r.read<String>('kind'),
          coins: r.read<int>('coins'),
          xp: r.read<int>('xp'),
          ref: r.readNullable<String>('ref'),
          note: r.read<String>('note'),
        ),
    ];
  }

  Future<PetsOverview> overview() async {
    final enabled = await enabledAt();
    final today = petDay(clock());
    final minutes =
        (await _db
                .customSelect(
                  'SELECT minutes FROM pets_days_v1 WHERE day=?',
                  variables: [Variable(today)],
                )
                .getSingleOrNull())
            ?.read<int>('minutes') ??
        0;
    final all = await pets();
    final companion = await companionId();
    return PetsOverview(
      enabledAt: enabled,
      balance: await balance(),
      todayMinutes: minutes,
      todayCredited: await _creditedTime(today),
      streak: enabled == null
          ? const StreakState(
              current: 0,
              best: 0,
              freezes: 0,
              frozenDays: [],
              earnedOn: [],
            )
          : await _replay(enabled),
      companion: all.where((p) => p.id == companion).firstOrNull,
      pets: all,
      recent: await ledger(limit: 20),
      bookOfDay:
          (await _db
                  .customSelect(
                    'SELECT note FROM pets_ledger_v1 WHERE dedup=?',
                    variables: [Variable('bookday:$today')],
                  )
                  .getSingleOrNull())
              ?.read<String>('note')
              .replaceFirst('Книга дня: ', ''),
      inventory: await inventory(),
      owned: await owned(),
    );
  }

  // ------------------------------------------------------------------ sync

  /// Recounts from the last synced day to today. Safe to call any number of
  /// times: every grant has a unique key, and only increases are written.
  Future<void> sync() async {
    final enabled = await enabledAt();
    if (enabled == null) return;
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final synced = DateTime.tryParse(await repository.meta(_syncedKey) ?? '');
    var day = DateTime(enabled.year, enabled.month, enabled.day);
    if (synced != null) {
      // The previous day is recounted: sessions may finish after midnight.
      final back = DateTime(synced.year, synced.month, synced.day - 1);
      if (back.isAfter(day)) day = back;
    }
    final reading = ReadingDailyTotals(repository);
    final audio = AudioDailyStore(repository);
    final minutes = <String, int>{};
    final test = await testMinutes();
    for (
      ;
      !day.isAfter(today);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      final next = DateTime(day.year, day.month, day.day + 1);
      final from = enabled.isAfter(day) ? enabled : day;
      final to = now.isBefore(next) ? now : next;
      final extra = test[petDay(day)] ?? 0;
      if (!to.isAfter(from)) {
        minutes[petDay(day)] = extra;
        continue;
      }
      final readMs = await reading.range(from, to);
      final listened = await audio.period(from, to);
      final audioMs = listened.days.values.fold(0, (a, b) => a + b);
      minutes[petDay(day)] = (readMs + audioMs) ~/ 60000 + extra;
    }
    await _db.transaction(() async {
      final books = await _bookCandidates(enabled, now);
      for (final e in minutes.entries) {
        await _db.customStatement(
          'INSERT INTO pets_days_v1(day,minutes) VALUES(?,?) '
          'ON CONFLICT(day) DO UPDATE SET minutes=MAX(minutes,excluded.minutes)',
          [e.key, e.value],
        );
        final credited = PetRules.creditedMinutes(e.value);
        final already = await _creditedTime(e.key);
        if (credited > already) {
          await _grant(
            day: e.key,
            kind: 'time',
            coins: credited - already,
            xp: credited - already,
            note: 'Чтение и прослушивание: ${_hm(credited)} за день',
            dedup: 'time:${e.key}:$credited',
          );
        }
      }
      for (final book in books) {
        await _grant(
          day: book.day,
          kind: 'book',
          coins: book.bonus,
          xp: book.bonus,
          ref: book.id,
          note: 'Книга дня: ${book.title}',
          dedup: 'bookday:${book.day}',
        );
      }
      final streak = await _replay(enabled);
      for (final d in streak.earnedOn) {
        await _grant(
          day: d,
          kind: 'freeze-earned',
          note: 'Заморозка серии за 7 дней подряд',
          dedup: 'freeze-earned:$d',
        );
      }
      for (final d in streak.frozenDays) {
        await _grant(
          day: d,
          kind: 'freeze-used',
          note: 'Заморозка сохранила серию',
          dedup: 'freeze-used:$d',
        );
      }
      for (final chest in PetRules.chests.entries) {
        if (streak.best >= chest.key) {
          await _grant(
            day: petDay(now),
            kind: 'chest',
            coins: chest.value,
            note: 'Сундук за ${chest.key} дней подряд',
            dedup: 'chest:${chest.key}',
          );
        }
      }
      await repository.setMeta(_syncedKey, petDay(today));
    });
  }

  Future<int> _creditedTime(String day) async =>
      (await _db
              .customSelect(
                "SELECT COALESCE(SUM(coins),0) AS s FROM pets_ledger_v1 WHERE kind='time' AND day=?",
                variables: [Variable(day)],
              )
              .getSingle())
          .read<int>('s');

  Future<StreakState> _replay(DateTime enabled) async {
    final rows = await _db
        .customSelect('SELECT day,minutes FROM pets_days_v1')
        .get();
    final bought = <String, int>{};
    for (final r
        in await _db
            .customSelect(
              "SELECT day,COUNT(*) AS n FROM pets_ledger_v1 WHERE kind='freeze-buy' GROUP BY day",
            )
            .get()) {
      bought[r.read<String>('day')] = r.read<int>('n');
    }
    return replayStreak(
      first: enabled,
      today: clock(),
      minutes: {
        for (final r in rows) r.read<String>('day'): r.read<int>('minutes'),
      },
      bought: bought,
    );
  }

  /// Writes one ledger entry unless its [dedup] key exists, and splits its
  /// experience: the companion gets all of it, other pets a tenth.
  Future<bool> _grant({
    required String day,
    required String kind,
    required String note,
    required String dedup,
    int coins = 0,
    int xp = 0,
    String? ref,
  }) async {
    final exists = await _db
        .customSelect(
          'SELECT 1 FROM pets_ledger_v1 WHERE dedup=?',
          variables: [Variable(dedup)],
        )
        .getSingleOrNull();
    if (exists != null) return false;
    final id = await _db.customInsert(
      'INSERT INTO pets_ledger_v1(at,day,kind,coins,xp,ref,note,dedup) VALUES(?,?,?,?,?,?,?,?)',
      variables: [
        Variable(clock().toUtc().toIso8601String()),
        Variable(day),
        Variable(kind),
        Variable(coins),
        Variable(xp),
        Variable(ref),
        Variable(note),
        Variable(dedup),
      ],
    );
    if (xp > 0) {
      final companion = await companionId();
      for (final pet
          in await _db.customSelect('SELECT id FROM pets_v1').get()) {
        final petId = pet.read<String>('id');
        await _db.customStatement(
          'INSERT INTO pets_xp_v1(ledger_id,pet_id,xp) VALUES(?,?,?)',
          [id, petId, petId == companion ? xp * 1.0 : xp * PetRules.otherShare],
        );
      }
    }
    return true;
  }

  // ------------------------------------------------------------ book of day

  /// Finished books from the local queue that may earn the day's bonus:
  /// marked after the section was enabled, recently, never rewarded before,
  /// and read or listened to here for at least [PetRules.bookMinutes].
  /// Per day the one with the most own time wins. The queue is emptied.
  Future<List<_BookOfDay>> _bookCandidates(
    DateTime enabled,
    DateTime now,
  ) async {
    final queue = await _db
        .customSelect('SELECT id,book_id,at FROM pets_finish_queue_v1')
        .get();
    if (queue.isEmpty) return [];
    final byDay = <String, Set<String>>{};
    for (final row in queue) {
      final raw = row.readNullable<String>('at');
      final at = raw == null ? now : DateTime.tryParse(raw)?.toLocal();
      if (at == null ||
          at.isBefore(enabled) ||
          now.difference(at) > PetRules.finishWindow) {
        continue;
      }
      (byDay[petDay(at)] ??= {}).add(row.read<String>('book_id'));
    }
    final result = <_BookOfDay>[];
    for (final e in byDay.entries) {
      final taken = await _db
          .customSelect(
            'SELECT 1 FROM pets_ledger_v1 WHERE dedup=?',
            variables: [Variable('bookday:${e.key}')],
          )
          .getSingleOrNull();
      if (taken != null) continue;
      _BookOfDay? best;
      for (final id in e.value) {
        final rewarded = await _db
            .customSelect(
              "SELECT 1 FROM pets_ledger_v1 WHERE kind='book' AND ref=?",
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (rewarded != null) continue;
        final (readMs, audioMs) = await _ownTime(id);
        final total = (readMs + audioMs) ~/ 60000;
        if (total < PetRules.bookMinutes) continue;
        if (best != null && best.minutes >= total) continue;
        final title =
            (await _db
                    .customSelect(
                      "SELECT json_extract(payload,'\$.title') AS t FROM records WHERE id=? AND json_valid(payload)",
                      variables: [Variable(id)],
                    )
                    .getSingleOrNull())
                ?.readNullable<String>('t') ??
            'без названия';
        best = _BookOfDay(
          id: id,
          day: e.key,
          title: title,
          minutes: total,
          // The size is estimated from own time: about a page per minute.
          bonus: PetRules.bookBonus(
            pages: readMs ~/ 60000,
            audioHours: audioMs / 3600000,
          ),
        );
      }
      if (best != null) result.add(best);
    }
    await _db.customStatement('DELETE FROM pets_finish_queue_v1 WHERE id<=?', [
      queue.map((r) => r.read<int>('id')).reduce(math.max),
    ]);
    return result;
  }

  /// Own time with a book on this device: reader spans and native audio.
  Future<(int, int)> _ownTime(String bookId) async {
    final read = await _db
        .customSelect(
          'SELECT COALESCE(SUM(i.active_ms),0) AS ms FROM reading_span_index_v1 i '
          'JOIN metadata m ON m.key=i.session_key '
          "WHERE json_valid(m.value) AND json_extract(m.value,'\$.bookId')=?",
          variables: [Variable(bookId)],
        )
        .getSingle();
    final audio = await _db
        .customSelect(
          'SELECT COALESCE(SUM(wall_ms),0) AS ms FROM audio_daily_totals_v1 WHERE book_id=?',
          variables: [Variable(bookId)],
        )
        .getSingle();
    return (read.read<int>('ms'), audio.read<int>('ms'));
  }

  static String _hm(int minutes) =>
      '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';
}

class _BookOfDay {
  final String id, day, title;
  final int minutes, bonus;
  const _BookOfDay({
    required this.id,
    required this.day,
    required this.title,
    required this.minutes,
    required this.bonus,
  });
}
