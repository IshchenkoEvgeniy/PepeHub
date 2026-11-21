import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pet_rules.dart';
import 'package:pepehub/pets/pets_service.dart';

/// A reading session of [minutes] starting at [start] (local time).
Future<void> _read(
  Repository repo,
  String id,
  String book,
  DateTime start,
  int minutes,
) => repo.setMeta(
  'reading-session:$id',
  jsonEncode({
    'id': id,
    'bookId': book,
    'startedAt': start.toUtc().toIso8601String(),
    'spans': [
      {
        'start': start.toUtc().toIso8601String(),
        'end': start.add(Duration(minutes: minutes)).toUtc().toIso8601String(),
        'activeMs': minutes * 60000,
      },
    ],
  }),
);

Future<void> _listen(
  Repository repo,
  String id,
  String book,
  DateTime start,
  int minutes,
) => AudioJournal(repo).put('audio_event', id, {
  'kind': 'listen',
  'bookId': book,
  'trackId': 'track',
  'wallMs': minutes * 60000,
  'positionMs': 0,
  'endMs': minutes * 60000,
  'speed': 1.0,
  'localDay': petDay(start),
  'at': start.toUtc().toIso8601String(),
  'offsetMinutes': start.timeZoneOffset.inMinutes,
});

void main() {
  group('rules', () {
    test('experience curve, levels and stages', () {
      expect(PetRules.xpForLevel(1), 27);
      expect(PetRules.levelForXp(0), 1);
      expect(PetRules.levelForXp(26), 1);
      expect(PetRules.levelForXp(27), 2);
      final toMax = PetRules.totalXpForLevel(100);
      // About 3.5 years at an hour a day (~65 experience with books).
      expect(toMax, 81473);
      expect(toMax / 65 / 365, closeTo(3.5, 0.1));
      expect(PetRules.totalXpForLevel(70) / 65 / 365, closeTo(1.5, 0.1));
      expect(PetRules.levelForXp(toMax), 100);
      expect(PetRules.levelForXp(toMax * 10), 100);
      expect(PetRules.stageForLevel(1), PetStage.baby);
      expect(PetRules.stageForLevel(24), PetStage.cub);
      expect(PetRules.stageForLevel(25), PetStage.teen);
      expect(PetRules.stageForLevel(100), PetStage.legend);
    });

    test('daily cap and book bonus', () {
      expect(PetRules.creditedMinutes(-5), 0);
      expect(PetRules.creditedMinutes(300), 240);
      expect(PetRules.bookBonus(), 50);
      expect(PetRules.bookBonus(pages: 320), 82);
      expect(PetRules.bookBonus(audioHours: 10), 200);
      expect(PetRules.bookBonus(pages: 5000), 300);
    });

    test('streak: 15 minutes, freezes and today pending', () {
      final first = DateTime(2026, 1, 1);
      Map<String, int> days(List<int> m) => {
        for (var i = 0; i < m.length; i++)
          petDay(DateTime(2026, 1, 1 + i)): m[i],
      };
      // 7 days earn a freeze, a missed day uses it, the streak survives.
      var s = replayStreak(
        first: first,
        today: DateTime(2026, 1, 10),
        minutes: days([20, 20, 20, 20, 20, 20, 20, 0, 15, 0]),
      );
      expect(s.current, 8);
      expect(s.frozenDays, ['2026-01-08']);
      expect(s.freezes, 0);
      // 14 minutes is not a counted day; without freezes the streak breaks.
      s = replayStreak(
        first: first,
        today: DateTime(2026, 1, 4),
        minutes: days([20, 14, 20, 0]),
      );
      expect(s.current, 1);
      expect(s.best, 1);
      // Stock never exceeds two, bought ones included.
      s = replayStreak(
        first: first,
        today: DateTime(2026, 1, 21),
        minutes: days(List.filled(21, 30)),
        bought: {'2026-01-02': 3},
      );
      expect(s.freezes, PetRules.maxFreezes);
      expect(s.current, 21);
    });
  });

  group('service', () {
    late AppDatabase db;
    late Repository repo;
    late DateTime now;
    late PetsService pets;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db);
      now = DateTime(2026, 11, 20, 10);
      pets = PetsService(repo, clock: () => now);
    });
    tearDown(() => db.close());

    test('counts only after enabling, once, with deltas and the cap', () async {
      await _read(repo, 'before', 'b1', DateTime(2026, 11, 20, 8), 30);
      await pets.sync();
      expect(await pets.balance(), 0, reason: 'not enabled yet');
      await pets.enable();
      await pets.sync();
      expect(await pets.balance(), 0, reason: 'no start capital');

      now = DateTime(2026, 11, 20, 12);
      await _read(repo, 'r1', 'b1', DateTime(2026, 11, 20, 10, 30), 40);
      await _listen(repo, 'a1', 'b2', DateTime(2026, 11, 20, 11), 20);
      await pets.sync();
      await pets.sync();
      expect(await pets.balance(), 60);

      await _read(repo, 'r2', 'b1', DateTime(2026, 11, 20, 12, 30), 300);
      now = DateTime(2026, 11, 20, 23);
      await pets.sync();
      expect(await pets.balance(), 240, reason: '4 hours a day at most');
      final companion = (await pets.overview()).companion!;
      expect(companion.xp, 240);

      // Deleting a session never takes coins back.
      await repo.db.customStatement(
        "DELETE FROM metadata WHERE key='reading-session:r2'",
      );
      await pets.sync();
      expect(await pets.balance(), 240);
    });

    test('a session across midnight is split between days', () async {
      now = DateTime(2026, 11, 19, 20);
      await pets.enable();
      await _read(repo, 'night', 'b1', DateTime(2026, 11, 19, 23, 30), 60);
      now = DateTime(2026, 11, 20, 9);
      await pets.sync();
      final entries = await pets.ledger();
      final byDay = {
        for (final e in entries.where((e) => e.kind == 'time')) e.day: e.coins,
      };
      expect(byDay, {'2026-11-19': 30, '2026-11-20': 30});
    });

    test('other pets get a tenth of the experience', () async {
      await pets.enable();
      await pets.createPet('fox', 'Лиса');
      await _read(repo, 'r', 'b1', DateTime(2026, 11, 20, 10), 50);
      now = DateTime(2026, 11, 20, 11);
      await pets.sync();
      final all = {for (final p in await pets.pets()) p.name: p.xp};
      expect(all, {'Кошка': 50, 'Лиса': closeTo(5, 1e-9)});
    });

    group('book of the day', () {
      Future<void> finish(String book, DateTime at) => repo.setMeta(
        'reading-dates:$book',
        jsonEncode({'finishedAt': at.toUtc().toIso8601String()}),
      );

      test(
        'needs 60 own minutes; the longest read wins; once per book',
        () async {
          await pets.enable();
          await _read(repo, 's1', 'short', DateTime(2026, 11, 20, 10), 59);
          await _read(repo, 's2', 'long', DateTime(2026, 11, 20, 11), 70);
          await _listen(repo, 'a', 'audio', DateTime(2026, 11, 20, 12, 30), 65);
          now = DateTime(2026, 11, 20, 14);
          await finish('short', now);
          await finish('long', now);
          await repo.setMeta('audio-status-override:audio', 'finished');
          await pets.sync();
          final books = (await pets.ledger()).where((e) => e.kind == 'book');
          expect(books.map((e) => e.ref), ['long']);
          expect(books.single.coins, PetRules.bookBonus(pages: 70));

          // The same book finished again on another day grants nothing.
          now = DateTime(2026, 11, 21, 10);
          await repo.setMeta('reading-dates:long', jsonEncode({}));
          await finish('long', now);
          await pets.sync();
          expect(
            (await pets.ledger()).where((e) => e.kind == 'book').length,
            1,
          );
        },
      );

      test(
        'ignores marks from before enabling or older than two days',
        () async {
          await _read(repo, 's', 'old', DateTime(2026, 11, 1, 10), 120);
          await _read(repo, 't', 'late', DateTime(2026, 11, 1, 13), 120);
          await finish('old', DateTime(2026, 11, 2));
          await pets.enable();
          // Processed long after it happened, e.g. a restored backup.
          await finish('late', DateTime(2026, 11, 20, 10, 30));
          now = DateTime(2026, 11, 23, 12);
          await pets.sync();
          expect((await pets.ledger()).where((e) => e.kind == 'book'), isEmpty);
        },
      );
    });

    test('a streak chest is granted once, even after a break', () async {
      now = DateTime(2026, 11, 1, 8);
      await pets.enable();
      for (var d = 0; d < 7; d++) {
        await _read(repo, 'd$d', 'b', DateTime(2026, 11, 1 + d, 9), 20);
      }
      now = DateTime(2026, 11, 7, 22);
      await pets.sync();
      // Seven more days after a two-day gap (one freeze, then a break).
      for (var d = 10; d < 17; d++) {
        await _read(repo, 'd$d', 'b', DateTime(2026, 11, 1 + d, 9), 20);
      }
      now = DateTime(2026, 11, 17, 22);
      await pets.sync();
      final chests = (await pets.ledger()).where((e) => e.kind == 'chest');
      expect(chests.map((e) => e.coins), [200]);
      expect(
        (await pets.ledger()).where((e) => e.kind == 'freeze-used'),
        hasLength(1),
      );
    });

    test('test minutes respect the cap and reset clears game data', () async {
      await pets.enable();
      await pets.addTestMinutes(60);
      await pets.sync();
      expect(await pets.balance(), 60);
      await pets.addTestMinutes(240);
      await pets.sync();
      expect(await pets.balance(), 240);
      expect(
        await repo.meta('reading-session:any'),
        isNull,
        reason: 'reading statistics are not touched',
      );
      await pets.resetAll();
      expect(await pets.balance(), 0);
      expect(await pets.enabledAt(), isNull);
      expect(await pets.pets(), isEmpty);
    });

    group('shop and care', () {
      Future<void> earn(int minutes) async {
        await pets.addTestMinutes(minutes);
        await pets.sync();
      }

      test('purchases, balance and inventory', () async {
        await pets.enable(species: PetSpecies.fox);
        expect((await pets.pets()).single.name, 'Лиса');
        await expectLater(
          pets.buy('food_kibble'),
          throwsA(isA<PetsActionError>()),
          reason: 'no coins yet',
        );
        await earn(240);
        await pets.buy('food_kibble');
        await pets.buy('food_kibble');
        await pets.buy('decor_book_stack');
        expect(await pets.balance(), 240 - 20 - 150);
        expect(await pets.inventory(), {'food_kibble': 2});
        expect(await pets.owned(), {'decor_book_stack'});
        await expectLater(
          pets.buy('decor_book_stack'),
          throwsA(isA<PetsActionError>()),
          reason: 'bought once',
        );
        await expectLater(
          pets.buy('decor_aquarium'),
          throwsA(isA<PetsActionError>()),
          reason: 'never below zero',
        );
        expect(await pets.balance(), 70);
      });

      test('feeding spends food and restores satiety', () async {
        await pets.enable();
        final pet = (await pets.pets()).single;
        expect(pet.satiety(now), 1, reason: 'arrives fed');
        now = now.add(const Duration(hours: 18));
        expect((await pets.pets()).single.satiety(now), closeTo(0.25, 1e-9));
        await expectLater(
          pets.feed(pet.id, 'food_kibble'),
          throwsA(isA<PetsActionError>()),
        );
        await earn(60);
        await pets.buy('food_kibble');
        await pets.feed(pet.id, 'food_kibble');
        // 6 hours left + 12 from kibble = 18 of 24.
        expect((await pets.pets()).single.satiety(now), closeTo(0.75, 1e-9));
        expect(await pets.inventory(), isEmpty);
        expect(
          (await pets.ledger()).where((e) => e.kind == 'feed'),
          hasLength(1),
        );
        now = now.add(const Duration(days: 3));
        expect((await pets.pets()).single.satiety(now), 0);
      });

      test('colors and accessories need to be owned', () async {
        await pets.enable(species: PetSpecies.dragon);
        final id = (await pets.pets()).single.id;
        await expectLater(
          pets.setColor(id, 'color_mint'),
          throwsA(isA<PetsActionError>()),
        );
        await earn(240);
        await pets.addTestMinutes(240, day: now.add(const Duration(days: 1)));
        now = now.add(const Duration(days: 1));
        await pets.sync();
        await pets.buy('acc_beanie');
        await pets.setAccessory(id, PetSocket.head, 'acc_beanie');
        await expectLater(
          pets.setAccessory(id, PetSocket.neck, 'acc_beanie'),
          throwsA(isA<PetsActionError>()),
          reason: 'wrong socket',
        );
        expect((await pets.pets()).single.accessories, {
          PetSocket.head: 'acc_beanie',
        });
        await pets.setAccessory(id, PetSocket.head, null);
        expect((await pets.pets()).single.accessories, isEmpty);
      });

      test('freezes can be bought while the stock has room', () async {
        await pets.enable();
        await earn(240);
        await pets.addTestMinutes(240, day: now.add(const Duration(days: 1)));
        await pets.addTestMinutes(240, day: now.add(const Duration(days: 2)));
        now = now.add(const Duration(days: 2));
        await pets.sync();
        await pets.buy('freeze');
        await pets.buy('freeze');
        expect((await pets.overview()).streak.freezes, 2);
        await expectLater(pets.buy('freeze'), throwsA(isA<PetsActionError>()));
      });
    });

    test('age follows the level', () {
      expect(PetRules.ageForLevel(1), '1 мес.');
      expect(PetRules.ageForLevel(10), '1 год');
      expect(PetRules.ageForLevel(25), '3 года');
      expect(PetRules.ageForLevel(100), '29 лет');
    });

    test('library cards and their filter are untouched', () async {
      await pets.enable();
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'pets_%'",
          )
          .get();
      expect(tables.map((r) => r.read<String>('name')).toSet(), {
        'pets_ledger_v1',
        'pets_xp_v1',
        'pets_v1',
        'pets_days_v1',
        'pets_finish_queue_v1',
        'pets_inventory_v1',
        'pets_owned_v1',
        'pets_eggs_v1',
        'pets_reserve_v1',
      });
      final meta = await db
          .customSelect("SELECT key FROM metadata WHERE key LIKE 'pets:%'")
          .get();
      expect(meta.map((r) => r.read<String>('key')).toSet(), {
        'pets:enabledAt',
        'pets:companion',
      });
    });
  });
}
