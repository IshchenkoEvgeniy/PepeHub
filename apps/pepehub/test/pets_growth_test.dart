import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pet_games.dart';
import 'package:pepehub/pets/pet_progress.dart';
import 'package:pepehub/pets/pets_service.dart';

void main() {
  group('rules', () {
    test('level rewards and the model of each stage', () {
      expect(PetGrowth.levelReward(9), 0);
      expect(PetGrowth.levelReward(10), 100);
      expect(PetGrowth.levelReward(100), 1000);
      expect(PetGrowth.modelAsset('fox', 1), 'assets/pets/fox_baby.glb');
      expect(PetGrowth.modelAsset('puppy', 10), 'assets/pets/puppy_cub.glb');
      expect(PetGrowth.modelAsset('bunny', 30), 'assets/pets/bunny_teen.glb');
      expect(PetGrowth.modelAsset('bunny', 95), 'assets/pets/bunny_adult.glb');
      expect(
        PetGrowth.modelAsset('cat', 5),
        'assets/pets/fox_baby.glb',
        reason: 'a removed species falls back to the fox',
      );
      expect(PetSpecies.values.map((s) => s.name), ['fox', 'puppy', 'bunny']);
    });

    test('mini-game coins and the daily limit', () {
      expect(PetGames.catchCoins(0), 0);
      expect(PetGames.catchCoins(17), 8);
      expect(PetGames.catchCoins(200), 30, reason: 'a round pays at most 30');
      expect(PetGames.memoryCoins(PetGames.memoryPairs, cleared: true), 30);
      expect(PetGames.memoryCoins(10, cleared: true), 22);
      expect(PetGames.memoryCoins(40, cleared: true), 5);
      expect(PetGames.memoryCoins(6, cleared: false), 0);
      expect(PetGames.payable(30, 0), 30);
      expect(PetGames.payable(30, 35), 15);
      expect(PetGames.payable(30, 50), 0);
    });
  });

  group('service', () {
    late AppDatabase db;
    late PetsService pets;
    late DateTime now;
    var started = false;
    setUp(() {
      started = false;
      db = AppDatabase(NativeDatabase.memory());
      now = DateTime(2026, 11, 20, 10);
      pets = PetsService(Repository(db), clock: () => now);
    });
    tearDown(() => db.close());

    /// [n] new days with [minutes] each; the first call starts today.
    Future<void> days(int n, [int minutes = 240]) async {
      for (var i = 0; i < n; i++) {
        if (started) now = now.add(const Duration(days: 1));
        started = true;
        await pets.addTestMinutes(minutes);
        await pets.sync();
      }
    }

    test('other species are bought at once, one each', () async {
      await pets.enable(species: PetSpecies.bunny);
      expect(pets.petOffers(await pets.pets()), [
        PetSpecies.fox,
        PetSpecies.puppy,
      ]);
      await expectLater(
        pets.buyPet(PetSpecies.fox),
        throwsA(isA<PetsActionError>()),
        reason: 'no coins yet',
      );
      await days(7);
      final before = await pets.balance();
      final id = await pets.buyPet(PetSpecies.fox);
      final all = await pets.pets();
      expect(all.firstWhere((p) => p.id == id).species, 'fox');
      expect(all.firstWhere((p) => p.id == id).satiety(now), 1);
      // The «second pet» achievement may pay on top of the price.
      expect(await pets.balance(), greaterThanOrEqualTo(before - petPrice));
      expect((await pets.unlockedAchievements()), contains('pets_2'));
      await expectLater(
        pets.buyPet(PetSpecies.fox),
        throwsA(isA<PetsActionError>()),
        reason: 'one pet per species',
      );
      expect(pets.petOffers(await pets.pets()), [PetSpecies.puppy]);
    });

    test('mini-games pay up to the daily limit and cheer the pet', () async {
      await pets.enable();
      final id = (await pets.pets()).single.id;
      await pets.cheer(id, -0.5);
      final mood = (await pets.moods())[id]!;
      expect(await pets.finishGame(PetGame.catchTreats, 60, petId: id), 30);
      expect(await pets.finishGame(PetGame.memory, 6, petId: id), 20);
      expect(
        await pets.finishGame(PetGame.memory, 6, petId: id),
        0,
        reason: '50 a day',
      );
      expect(await pets.gameCoinsToday(), PetGames.dailyCoins);
      expect((await pets.overview()).gameCoinsToday, PetGames.dailyCoins);
      expect((await pets.moods())[id]!, greaterThan(mood));
      now = now.add(const Duration(days: 1));
      expect(await pets.finishGame(PetGame.catchTreats, 10, petId: id), 5);
      final journal = await pets.ledger(limit: 50);
      expect(journal.where((e) => e.kind == 'game').map((e) => e.coins), [
        5,
        20,
        30,
      ]);
      expect(
        journal.where((e) => e.kind == 'game').every((e) => e.xp == 0),
        isTrue,
        reason: 'experience comes from reading only',
      );
    });

    test('achievements and round levels pay once', () async {
      await pets.enable();
      await days(3); // 720 minutes = 12 hours, level ≥ 10
      final unlocked = await pets.unlockedAchievements();
      expect(unlocked, contains('hours_10'));
      expect(await pets.owned(), contains('acc_glasses'));
      final journal = await pets.ledger(limit: 200);
      expect(journal.where((e) => e.kind == 'level').map((e) => e.coins), [
        100,
      ]);
      await pets.sync();
      await pets.sync();
      expect(
        (await pets.ledger(limit: 200)).where((e) => e.kind != 'time').length,
        journal.where((e) => e.kind != 'time').length,
        reason: 'idempotent',
      );
      await expectLater(
        pets.setHonor('streak_7'),
        throwsA(isA<PetsActionError>()),
      );
      await days(5);
      await pets.setHonor('streak_7');
      expect((await pets.overview()).honor, 'streak_7');
      await pets.setHonor(null);
      expect((await pets.overview()).honor, isNull);
    });

    test('accessories go on any socket together', () async {
      await pets.enable();
      final id = (await pets.pets()).single.id;
      await days(4);
      await pets.buy('acc_scarf');
      await pets.buy('acc_beanie');
      await pets.setAccessory(id, PetSocket.neck, 'acc_scarf');
      await pets.setAccessory(id, PetSocket.head, 'acc_beanie');
      expect((await pets.pets()).single.accessories, {
        PetSocket.neck: 'acc_scarf',
        PetSocket.head: 'acc_beanie',
      });
      await expectLater(
        pets.setAccessory(id, PetSocket.face, 'acc_scarf'),
        throwsA(isA<PetsActionError>()),
        reason: 'wrong socket',
      );
      expect(() => pets.buy('acc_glasses'), throwsA(isA<PetsActionError>()));
    });
  });
}
