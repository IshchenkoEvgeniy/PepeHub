import 'pet_catalog.dart';
import 'pet_rules.dart';

/// Growth and achievements of the pets section. Pure data and rules; the
/// service applies them. (Paths, talents, eggs and merging were removed in
/// schema 13: the game is a pet per species, bought at once.)

// ------------------------------------------------------------ achievements

enum AchievementMetric { books, hours, streak, pets, games, level }

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
    id: 'pets_2',
    title: 'Новый друг',
    description: 'Завести второго питомца.',
    metric: AchievementMetric.pets,
    target: 2,
    coins: 200,
  ),
  PetAchievement(
    id: 'pets_3',
    title: 'Вся компания',
    description: 'Лиса, щенок и кролик живут вместе.',
    metric: AchievementMetric.pets,
    target: 3,
    honor: 'Собиратель',
  ),
  PetAchievement(
    id: 'games_300',
    title: 'Игрок',
    description: 'Выиграть 300 монет в мини-играх.',
    metric: AchievementMetric.games,
    target: 300,
    honor: 'Весельчак',
  ),
  PetAchievement(
    id: 'level_25',
    title: 'Подрос',
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
  /// [gameCoins]: coins ever won in mini-games.
  final int books, minutes, bestStreak, pets, gameCoins, maxLevel;
  const AchievementProgress({
    this.books = 0,
    this.minutes = 0,
    this.bestStreak = 0,
    this.pets = 0,
    this.gameCoins = 0,
    this.maxLevel = 1,
  });

  int of(AchievementMetric metric) => switch (metric) {
    AchievementMetric.books => books,
    AchievementMetric.hours => minutes ~/ 60,
    AchievementMetric.streak => bestStreak,
    AchievementMetric.pets => pets,
    AchievementMetric.games => gameCoins,
    AchievementMetric.level => maxLevel,
  };

  bool reached(PetAchievement a) => of(a.metric) >= a.target;
}

// ------------------------------------------------------------- growth rules

abstract final class PetGrowth {
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

  /// Model asset for a pet: `assets/pets/<species>_<stage>.glb`.
  static String modelAsset(String species, int level) {
    final s = PetSpecies.byId(species)?.name ?? PetSpecies.fox.name;
    return 'assets/pets/${s}_${modelStage(level)}.glb';
  }

  /// Extra scale of the adult model for later stages.
  static double stageScale(int level) =>
      switch (PetRules.stageForLevel(level)) {
        PetStage.mature => 1.08,
        PetStage.elder || PetStage.legend => 1.14,
        _ => 1,
      };
}
