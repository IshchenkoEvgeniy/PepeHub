import 'dart:math' as math;

import 'pet_catalog.dart';
import 'pet_rules.dart';

/// Stage 4 of the pets section: growth paths, talents, ranks, eggs and
/// achievements. Pure data and rules; the service applies them.

// ------------------------------------------------------------------- paths

/// Adult looks chosen once at [PetRules.pathLevel]. Models:
/// `assets/pets/<species>_adult_<model>.glb`.
enum PetPath {
  catBookish(
    PetSpecies.cat,
    'Книжная',
    'Пушистая, с кисточками на ушах',
    'bookish',
  ),
  catNight(PetSpecies.cat, 'Ночная', 'Гладкая, с длинным хвостом', 'night'),
  foxForest(PetSpecies.fox, 'Лесная', 'Пышный хвост и мягкий мех', 'forest'),
  foxFire(
    PetSpecies.fox,
    'Огненная',
    'Острые уши, хвост языком пламени',
    'fire',
  ),
  dragonStar(
    PetSpecies.dragon,
    'Звёздный',
    'Большие крылья и тонкие рога',
    'star',
  ),
  dragonStone(
    PetSpecies.dragon,
    'Каменный',
    'Крепкий, с гребнем и толстыми рогами',
    'stone',
  );

  final PetSpecies species;
  final String label, description, model;
  const PetPath(this.species, this.label, this.description, this.model);

  static PetPath? byId(String? id) =>
      values.where((p) => p.name == id).firstOrNull;
  static List<PetPath> of(String species) =>
      values.where((p) => p.species.name == species).toList();
}

// ----------------------------------------------------------------- talents

/// What a talent changes in the scene. Talents are cosmetic only: none of
/// them affects coins or experience.
enum TalentEffect { greet, spin, jump, stretch, bedSpot, nightOwl, slot }

class PetTalent {
  final String id, title, description;
  final int cost, minLevel;
  final TalentEffect effect;
  const PetTalent({
    required this.id,
    required this.title,
    required this.description,
    required this.cost,
    required this.minLevel,
    required this.effect,
  });
}

const petTalents = <PetTalent>[
  PetTalent(
    id: 'greet',
    title: 'Встреча',
    description: 'Радуется, когда вы открываете Дом.',
    cost: 1,
    minLevel: 5,
    effect: TalentEffect.greet,
  ),
  PetTalent(
    id: 'spin',
    title: 'Кружиться',
    description: 'В ответ на нажатие кружится на месте.',
    cost: 2,
    minLevel: 10,
    effect: TalentEffect.spin,
  ),
  PetTalent(
    id: 'jump',
    title: 'Прыжок',
    description: 'Радость — высокий прыжок.',
    cost: 2,
    minLevel: 15,
    effect: TalentEffect.jump,
  ),
  PetTalent(
    id: 'stretch',
    title: 'Потягушки',
    description: 'Иногда потягивается, пока ждёт.',
    cost: 3,
    minLevel: 25,
    effect: TalentEffect.stretch,
  ),
  PetTalent(
    id: 'bed',
    title: 'Место на кровати',
    description: 'Перебирается с пуфа на кровать.',
    cost: 3,
    minLevel: 30,
    effect: TalentEffect.bedSpot,
  ),
  PetTalent(
    id: 'night_owl',
    title: 'Сова',
    description: 'Не спит ночью — читает вместе с вами.',
    cost: 3,
    minLevel: 40,
    effect: TalentEffect.nightOwl,
  ),
  PetTalent(
    id: 'slot',
    title: 'Ещё одна ячейка',
    description: '+1 ячейка для аксессуара.',
    cost: 4,
    minLevel: 50,
    effect: TalentEffect.slot,
  ),
];

PetTalent? petTalent(String id) =>
    petTalents.where((t) => t.id == id).firstOrNull;

// ------------------------------------------------------------------- ranks

/// One merge step: rank r → r+1.
class RankStep {
  final int copies, level, fee;
  final String label, gives;
  const RankStep(this.copies, this.level, this.fee, this.label, this.gives);
}

/// ★ = 2 pets of a species, ★★ = 4, ★★★ = 8 (main + copies).
const rankSteps = <RankStep>[
  RankStep(1, 25, 500, '★', 'Блеск, +1 ячейка аксессуара'),
  RankStep(2, 50, 1500, '★★', 'Частицы вокруг питомца, +2 очка таланта'),
  RankStep(4, 70, 3000, '★★★', 'Аура и титул'),
];

String rankStars(int rank) => '★' * rank;

// -------------------------------------------------------------------- eggs

/// A new species is bought at [speciesEggPrice] and hatches after
/// [speciesEggMinutes] of credited reading; a copy of an owned one costs and
/// takes half.
const speciesEggPrice = 1500;
const speciesEggMinutes = 600;
const copyEggPrice = speciesEggPrice ~/ 2;
const copyEggMinutes = speciesEggMinutes ~/ 2;

/// The second incubator slot (shop item).
const incubatorSlotId = 'incubator_slot';
const incubatorSlotPrice = 3000;
const talentResetPrice = 1000;

// ------------------------------------------------------------ achievements

enum AchievementMetric { books, hours, streak, hatched, rank, level }

class PetAchievement {
  final String id, title, description;
  final AchievementMetric metric;
  final int target, coins;

  /// Reward-only item (color or accessory) unlocked for every pet.
  final String? item;

  /// Title the owner can show in the pets profile.
  final String? honor;
  const PetAchievement({
    required this.id,
    required this.title,
    required this.description,
    required this.metric,
    required this.target,
    this.coins = 0,
    this.item,
    this.honor,
  });

  String get titleId => 'title_$id';
}

/// Counted only from the moment the pets section was enabled.
const petAchievements = <PetAchievement>[
  PetAchievement(
    id: 'books_1',
    title: 'Первая книга',
    description: 'Получить бонус «книга дня».',
    metric: AchievementMetric.books,
    target: 1,
    coins: 100,
    honor: 'Читатель',
  ),
  PetAchievement(
    id: 'books_10',
    title: 'Десять книг',
    description: '10 книг дня.',
    metric: AchievementMetric.books,
    target: 10,
    coins: 300,
    item: 'color_amber',
  ),
  PetAchievement(
    id: 'books_50',
    title: 'Полсотни',
    description: '50 книг дня.',
    metric: AchievementMetric.books,
    target: 50,
    coins: 1000,
    honor: 'Книжный червь',
  ),
  PetAchievement(
    id: 'books_100',
    title: 'Сотня книг',
    description: '100 книг дня.',
    metric: AchievementMetric.books,
    target: 100,
    coins: 3000,
    honor: 'Библиофил',
  ),
  PetAchievement(
    id: 'hours_10',
    title: '10 часов',
    description: '10 засчитанных часов чтения и прослушивания.',
    metric: AchievementMetric.hours,
    target: 10,
    item: 'acc_glasses',
  ),
  PetAchievement(
    id: 'hours_100',
    title: '100 часов',
    description: '100 засчитанных часов.',
    metric: AchievementMetric.hours,
    target: 100,
    coins: 500,
    item: 'color_aurora',
  ),
  PetAchievement(
    id: 'hours_500',
    title: '500 часов',
    description: '500 засчитанных часов.',
    metric: AchievementMetric.hours,
    target: 500,
    coins: 1500,
    honor: 'Неутомимый',
  ),
  PetAchievement(
    id: 'hours_1000',
    title: 'Тысяча часов',
    description: '1000 засчитанных часов.',
    metric: AchievementMetric.hours,
    target: 1000,
    coins: 5000,
    honor: 'Тысяча часов',
  ),
  PetAchievement(
    id: 'streak_7',
    title: 'Неделя',
    description: 'Серия 7 дней.',
    metric: AchievementMetric.streak,
    target: 7,
    honor: 'Неделя чтения',
  ),
  PetAchievement(
    id: 'streak_30',
    title: 'Месяц',
    description: 'Серия 30 дней.',
    metric: AchievementMetric.streak,
    target: 30,
    item: 'color_sunset',
  ),
  PetAchievement(
    id: 'streak_100',
    title: 'Сто дней',
    description: 'Серия 100 дней.',
    metric: AchievementMetric.streak,
    target: 100,
    honor: 'Сто дней',
  ),
  PetAchievement(
    id: 'streak_365',
    title: 'Год',
    description: 'Серия 365 дней.',
    metric: AchievementMetric.streak,
    target: 365,
    honor: 'Год без перерыва',
  ),
  PetAchievement(
    id: 'hatch_1',
    title: 'Первое яйцо',
    description: 'Вырастить питомца или копию из яйца.',
    metric: AchievementMetric.hatched,
    target: 1,
    coins: 200,
  ),
  PetAchievement(
    id: 'rank_1',
    title: 'Первая звезда',
    description: 'Объединить питомца с копией.',
    metric: AchievementMetric.rank,
    target: 1,
    honor: 'Собиратель',
  ),
  PetAchievement(
    id: 'level_25',
    title: 'Свой путь',
    description: 'Питомец 25-го уровня.',
    metric: AchievementMetric.level,
    target: 25,
    coins: 300,
  ),
  PetAchievement(
    id: 'level_100',
    title: 'Легенда',
    description: 'Питомец 100-го уровня.',
    metric: AchievementMetric.level,
    target: 100,
    honor: 'Хранитель легенды',
  ),
];

PetAchievement? petAchievement(String id) =>
    petAchievements.where((a) => a.id == id).firstOrNull;

/// Values the achievements are checked against.
class AchievementProgress {
  final int books, minutes, bestStreak, hatched, maxRank, maxLevel;
  const AchievementProgress({
    this.books = 0,
    this.minutes = 0,
    this.bestStreak = 0,
    this.hatched = 0,
    this.maxRank = 0,
    this.maxLevel = 1,
  });

  int of(AchievementMetric metric) => switch (metric) {
    AchievementMetric.books => books,
    AchievementMetric.hours => minutes ~/ 60,
    AchievementMetric.streak => bestStreak,
    AchievementMetric.hatched => hatched,
    AchievementMetric.rank => maxRank,
    AchievementMetric.level => maxLevel,
  };

  bool reached(PetAchievement a) => of(a.metric) >= a.target;
}

// ------------------------------------------------------------- growth rules

abstract final class PetGrowth {
  /// One talent point per [PetRules.talentEvery] levels, +2 at rank ★★.
  static int talentPoints(int level, int rank) =>
      math.min(level, PetRules.maxLevel) ~/ PetRules.talentEvery +
      (rank >= 2 ? 2 : 0);

  static int spent(Iterable<String> talents) =>
      talents.map(petTalent).nonNulls.fold(0, (a, t) => a + t.cost);

  /// Accessory slots: 1 for baby and cub, 2 teen, 3 adult and mature,
  /// 4 elder and legend; +1 at rank ★ and +1 from the talent. Never more
  /// than there are sockets.
  static int accessorySlots(int level, int rank, Iterable<String> talents) {
    final stage = PetRules.stageForLevel(level);
    final base = switch (stage) {
      PetStage.baby || PetStage.cub => 1,
      PetStage.teen => 2,
      PetStage.adult || PetStage.mature => 3,
      PetStage.elder || PetStage.legend => 4,
    };
    final extra = (rank >= 1 ? 1 : 0) + (talents.contains('slot') ? 1 : 0);
    return math.min(PetSocket.values.length, base + extra);
  }

  /// Round levels 10, 20 … 100 pay 100 × (level / 10) coins.
  static int levelReward(int level) =>
      level % 10 == 0 && level > 0 ? 100 * (level ~/ 10) : 0;

  /// Model stage of the scene for [level]: mature, elder and legend reuse
  /// the adult model with scale and effects.
  static String modelStage(int level) {
    final stage = PetRules.stageForLevel(level);
    return switch (stage) {
      PetStage.baby => 'baby',
      PetStage.cub => 'cub',
      PetStage.teen => 'teen',
      _ => 'adult',
    };
  }

  /// Model asset for a pet. An adult without a chosen path keeps the teen
  /// model until the owner picks one.
  static String modelAsset(String species, int level, String? path) {
    final s = PetSpecies.byId(species)?.name ?? 'cat';
    final stage = modelStage(level);
    final p = PetPath.byId(path);
    if (stage == 'adult') {
      return p == null || p.species.name != s
          ? 'assets/pets/${s}_teen.glb'
          : 'assets/pets/${s}_adult_${p.model}.glb';
    }
    return 'assets/pets/${s}_$stage.glb';
  }

  /// Extra scale of the adult model for later stages.
  static double stageScale(int level) =>
      switch (PetRules.stageForLevel(level)) {
        PetStage.mature => 1.08,
        PetStage.elder || PetStage.legend => 1.14,
        _ => 1,
      };
}
