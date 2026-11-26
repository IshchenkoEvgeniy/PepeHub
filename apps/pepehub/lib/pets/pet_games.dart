import 'dart:math' as math;

/// Mini-games of the pets section. They pay coins only — experience still
/// comes from reading — and all games together pay at most
/// [PetGames.dailyCoins] a day. Each game also cheers the pet up.
enum PetGame {
  catchTreats(
    'Поймай угощение',
    'Двигайте питомца и ловите вкусное. Колючки отнимают очки.',
  ),
  memory('Найди пару', 'Открывайте карточки и находите одинаковые.');

  final String title, description;
  const PetGame(this.title, this.description);

  static PetGame? byId(String id) =>
      values.where((g) => g.name == id).firstOrNull;
}

abstract final class PetGames {
  /// Coins from all mini-games per local day.
  static const dailyCoins = 50;

  /// Length of a «Поймай угощение» round.
  static const catchSeconds = 40;

  /// Cards of «Найди пару»: this many pairs (a 4×3 grid).
  static const memoryPairs = 6;

  /// Catch: a coin per two points, up to 30 for one round.
  static int catchCoins(int score) => (score ~/ 2).clamp(0, 30).toInt();

  /// Memory: 30 for a perfect game (every pair at the first try), two less
  /// for each extra move, at least 5 once the board is cleared.
  static int memoryCoins(int moves, {required bool cleared}) =>
      cleared ? (30 - 2 * (moves - memoryPairs)).clamp(5, 30).toInt() : 0;

  static int coins(PetGame game, int score, {bool cleared = true}) =>
      switch (game) {
        PetGame.catchTreats => catchCoins(score),
        PetGame.memory => memoryCoins(score, cleared: cleared),
      };

  /// What is paid out of [coins] when [today] were already won today.
  static int payable(int coins, int today) =>
      math.max(0, math.min(coins, dailyCoins - today));
}
