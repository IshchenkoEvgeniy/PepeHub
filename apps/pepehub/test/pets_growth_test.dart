import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pet_progress.dart';
import 'package:pepehub/pets/pets_service.dart';

void main() {
  group('rules', () {
    test('talent points, accessory slots and level rewards', () {
      expect(PetGrowth.talentPoints(4, 0), 0);
      expect(PetGrowth.talentPoints(5, 0), 1);
      expect(PetGrowth.talentPoints(100, 0), 20);
      expect(PetGrowth.talentPoints(100, 2), 22, reason: '★★ adds two');
      expect(PetGrowth.accessorySlots(1, 0, const {}), 1);
      expect(PetGrowth.accessorySlots(25, 0, const {}), 2);
      expect(PetGrowth.accessorySlots(45, 1, const {}), 4);
      expect(
        PetGrowth.accessorySlots(90, 1, const {'slot'}),
        PetSocket.values.length,
        reason: 'never more than sockets',
      );
      expect(PetGrowth.levelReward(9), 0);
      expect(PetGrowth.levelReward(10), 100);
      expect(PetGrowth.levelReward(100), 1000);
      // Talents fit into the points of level 100.
      expect(
        PetGrowth.spent(petTalents.map((t) => t.id)),
        lessThanOrEqualTo(20),
      );
    });

    test('model follows stage and path', () {
      expect(PetGrowth.modelAsset('cat', 1, null), 'assets/pets/cat_baby.glb');
      expect(PetGrowth.modelAsset('cat', 10, null), 'assets/pets/cat_cub.glb');
      expect(PetGrowth.modelAsset('fox', 30, null), 'assets/pets/fox_teen.glb');
      expect(
        PetGrowth.modelAsset('fox', 50, null),
        'assets/pets/fox_teen.glb',
        reason: 'no path yet',
      );
      expect(
        PetGrowth.modelAsset('dragon', 95, 'dragonStone'),
        'assets/pets/dragon_adult_stone.glb',
      );
      expect(
        PetGrowth.modelAsset('cat', 50, 'foxFire'),
        'assets/pets/cat_teen.glb',
        reason: 'a path of another species is ignored',
      );
      for (final s in PetSpecies.values) {
        expect(PetPath.of(s.name), hasLength(2));
      }
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

    Future<Pet> pet(String id) async =>
        (await pets.pets()).firstWhere((p) => p.id == id);

    test('eggs: buy, hatch a new species, then copies', () async {
      await pets.enable(species: PetSpecies.cat);
      final offers0 = pets.eggOffers(await pets.pets(), const []);
      expect(
        {for (final o in offers0) o.species: o.copy},
        {PetSpecies.cat: true, PetSpecies.fox: false, PetSpecies.dragon: false},
      );
      await expectLater(
        pets.buyEgg(PetSpecies.fox),
        throwsA(isA<PetsActionError>()),
        reason: 'no coins',
      );
      await days(7);
      final before = await pets.balance();
      await pets.buyEgg(PetSpecies.fox);
      expect(await pets.balance(), before - speciesEggPrice);
      await expectLater(
        pets.buyEgg(PetSpecies.dragon),
        throwsA(isA<PetsActionError>()),
        reason: 'one slot',
      );
      var egg = (await pets.eggs()).single;
      expect(egg.progress, 0, reason: 'past minutes do not count');
      await expectLater(pets.hatch(egg.id), throwsA(isA<PetsActionError>()));
      await days(3, 240); // 720 ≥ 600 minutes
      egg = (await pets.eggs()).single;
      expect(egg.ready, isTrue);
      final fox = await pets.hatch(egg.id);
      expect(fox, isNotNull);
      expect((await pet(fox!)).species, 'fox');
      expect(await pets.eggs(), isEmpty);
      expect((await pets.unlockedAchievements()).contains('hatch_1'), isTrue);
      // A copy egg is half price and goes to the reserve.
      final b = await pets.balance();
      await pets.buyEgg(PetSpecies.fox);
      expect(await pets.balance(), b - copyEggPrice);
      expect((await pets.eggs()).single.minutes, copyEggMinutes);
      await days(2);
      await pets.hatch((await pets.eggs()).single.id);
      expect(await pets.reserve(), {'fox': 1});
      expect(
        (await pets.pets()).where((p) => p.species == 'fox'),
        hasLength(1),
      );
    });

    test('second incubator slot', () async {
      await pets.enable();
      await days(26);
      await pets.buy(incubatorSlotId);
      expect(await pets.incubatorSlots(), 2);
      await pets.buyEgg(PetSpecies.fox);
      await pets.buyEgg(PetSpecies.dragon);
      expect(await pets.eggs(), hasLength(2));
      await days(3);
      expect(
        (await pets.eggs()).every((e) => e.ready),
        isTrue,
        reason: 'both grow from the same minutes',
      );
    });

    test('path from level 25, once, for its own species', () async {
      await pets.enable(species: PetSpecies.fox);
      final id = (await pets.pets()).single.id;
      await expectLater(
        pets.choosePath(id, PetPath.foxFire),
        throwsA(isA<PetsActionError>()),
        reason: 'level too low',
      );
      await days(14);
      expect((await pet(id)).level, greaterThanOrEqualTo(25));
      expect((await pet(id)).pathPending, isTrue);
      await expectLater(
        pets.choosePath(id, PetPath.catNight),
        throwsA(isA<PetsActionError>()),
      );
      await pets.choosePath(id, PetPath.foxFire);
      expect((await pet(id)).path, 'foxFire');
      await expectLater(
        pets.choosePath(id, PetPath.foxForest),
        throwsA(isA<PetsActionError>()),
      );
    });

    test('talents spend points; a reset costs coins', () async {
      await pets.enable();
      final id = (await pets.pets()).single.id;
      await days(6);
      final level = (await pet(id)).level;
      expect(level, inInclusiveRange(15, 24));
      await pets.learnTalent(id, 'greet');
      await pets.learnTalent(id, 'spin');
      expect((await pet(id)).talentPointsFree, level ~/ 5 - 3);
      await expectLater(
        pets.learnTalent(id, 'bed'),
        throwsA(isA<PetsActionError>()),
        reason: 'level 30 needed',
      );
      expect((await pet(id)).has(TalentEffect.spin), isTrue);
      final b = await pets.balance();
      await pets.resetTalents(id);
      expect(await pets.balance(), b - talentResetPrice);
      expect((await pet(id)).talents, isEmpty);
    });

    test('merge needs the level, copies and coins', () async {
      await pets.enable(species: PetSpecies.dragon);
      final id = (await pets.pets()).single.id;
      await days(8);
      await pets.buyEgg(PetSpecies.dragon);
      await days(2);
      await pets.hatch((await pets.eggs()).single.id);
      expect(await pets.reserve(), {'dragon': 1});
      await expectLater(
        pets.merge(id),
        throwsA(isA<PetsActionError>()),
        reason: 'level 25 needed',
      );
      await days(6);
      expect((await pet(id)).level, greaterThanOrEqualTo(25));
      final b = await pets.balance();
      await pets.merge(id);
      expect((await pet(id)).rank, 1);
      expect(await pets.reserve(), isEmpty);
      // Level reward and achievement coins may land in the same call.
      expect(await pets.balance(), greaterThanOrEqualTo(b - 500));
      expect((await pets.unlockedAchievements()).contains('rank_1'), isTrue);
      await expectLater(pets.merge(id), throwsA(isA<PetsActionError>()));
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

    test('accessory slots limit what is worn', () async {
      await pets.enable();
      final id = (await pets.pets()).single.id;
      await days(4);
      await pets.buy('acc_scarf');
      await pets.buy('acc_beanie');
      await pets.setAccessory(id, PetSocket.neck, 'acc_scarf');
      await expectLater(
        pets.setAccessory(id, PetSocket.head, 'acc_beanie'),
        throwsA(isA<PetsActionError>()),
        reason: 'a cub has one slot',
      );
      await pets.setAccessory(id, PetSocket.neck, null);
      await pets.setAccessory(id, PetSocket.head, 'acc_beanie');
      expect(() => pets.buy('acc_glasses'), throwsA(isA<PetsActionError>()));
    });
  });
}
