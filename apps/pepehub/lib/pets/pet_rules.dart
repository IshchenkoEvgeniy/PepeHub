import 'dart:math' as math;

/// Pure rules of the pets section (concept: «PepeHub — Питомник»).
/// No database, no clock: everything is passed in, so tests pin it exactly.
abstract final class PetRules {
  /// Minutes of reading and listening credited per day, shared.
  static const dailyMinutes = 240;

  /// A day counts towards the streak from this many minutes.
  static const streakMinutes = 15;

  /// Book of the day: minimum own time in PepeHub on this device.
  static const bookMinutes = 60;

  /// Finish events older than this when processed are ignored (restores).
  static const finishWindow = Duration(days: 2);

  static const maxLevel = 100;

  /// Share of experience for pets other than the companion.
  static const otherShare = 0.1;

  /// Streak chests, each granted once ever: days → coins.
  static const chests = {7: 200, 30: 1000, 100: 5000, 365: 15000};

  /// Freeze stock cap; one freeze is earned per 7 counted days in a row.
  static const maxFreezes = 2;
  static const freezeEvery = 7;

  static int creditedMinutes(int minutes) =>
      minutes.clamp(0, dailyMinutes).toInt();

  /// Book bonus: 50 + 1 per 10 pages (audio: 15 per hour), up to 300.
  /// Coins and experience are the same amount.
  static int bookBonus({int? pages, double? audioHours}) {
    var bonus = 50;
    if (pages != null && pages > 0) bonus += pages ~/ 10;
    if (audioHours != null && audioHours > 0) {
      bonus += (audioHours * 15).floor();
    }
    return math.min(bonus, 300);
  }

  /// Experience needed to go from [level] to the next one.
  static int xpForLevel(int level) => (30 + 2.5 * math.pow(level, 1.5)).round();

  /// Total experience needed to reach [level] (level 1 needs 0).
  static int totalXpForLevel(int level) {
    var total = 0;
    for (var l = 1; l < level.clamp(1, maxLevel); l++) {
      total += xpForLevel(l);
    }
    return total;
  }

  static int levelForXp(int xp) {
    var level = 1, left = xp;
    while (level < maxLevel && left >= xpForLevel(level)) {
      left -= xpForLevel(level);
      level++;
    }
    return level;
  }

  /// Hours from a full meal to hungry.
  static const fullHours = 24;

  /// 1 right after a full meal, 0 a day later; never fed counts as hungry.
  static double satiety(DateTime? fedAt, DateTime now) {
    if (fedAt == null) return 0;
    final hours = now.difference(fedAt).inMinutes / 60;
    return (1 - hours / fullHours).clamp(0, 1).toDouble();
  }

  /// [fedAt] stores «full until minus a day»: food adds [hours] of satiety
  /// on top of what is left, never above full.
  static DateTime fedAfter(DateTime? fedAt, DateTime now, int hours) {
    final left = satiety(fedAt, now) * fullHours;
    final total = math.min(fullHours.toDouble(), left + hours);
    return now.subtract(Duration(minutes: ((fullHours - total) * 60).round()));
  }

  /// Age shown in the profile, derived from the level (concept table):
  /// a pet not chosen for a while does not grow older.
  static String ageForLevel(int level) {
    // (from level, to level, from months, to months)
    const spans = [
      (1, 9, 0, 12),
      (10, 24, 12, 36),
      (25, 44, 36, 84),
      (45, 69, 84, 180),
      (70, 89, 180, 300),
      (90, 100, 300, 360),
    ];
    for (final (a, b, from, to) in spans) {
      if (level <= b) {
        final months = from + ((level - a) * (to - from) / (b - a + 1)).round();
        if (months < 12) return '${math.max(1, months)} мес.';
        final years = months ~/ 12;
        return '$years ${_years(years)}';
      }
    }
    return '30 лет';
  }

  static String _years(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'год';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'года';
    return 'лет';
  }

  static PetStage stageForLevel(int level) => PetStage.values.lastWhere(
    (s) => level >= s.fromLevel,
    orElse: () => PetStage.baby,
  );
}

enum PetStage {
  baby('Малыш', 1),
  cub('Детёныш', 10),
  teen('Подросток', 25),
  adult('Взрослый', 45),
  mature('Зрелый', 70),
  elder('Старейшина', 90),
  legend('Легенда', 100);

  final String label;
  final int fromLevel;
  const PetStage(this.label, this.fromLevel);
}

/// Result of replaying the days since the pets section was enabled.
class StreakState {
  /// Counted days in a row ending today or yesterday (today may be pending).
  final int current;

  /// Longest streak ever; chests depend on it, so a break never re-grants.
  final int best;

  /// Freezes left in stock (earned minus used, capped).
  final int freezes;

  /// Days closed by a freeze, `yyyy-mm-dd`.
  final List<String> frozenDays;

  /// Days a freeze was earned on.
  final List<String> earnedOn;
  const StreakState({
    required this.current,
    required this.best,
    required this.freezes,
    required this.frozenDays,
    required this.earnedOn,
  });
}

/// Replays days from [first] to [today] (local calendar days).
/// [minutes] maps `yyyy-mm-dd` to counted minutes; [bought] maps a day to
/// freezes bought that day. A missed day before today consumes a freeze when
/// one is in stock. Today is never missed: it is still in progress.
StreakState replayStreak({
  required DateTime first,
  required DateTime today,
  required Map<String, int> minutes,
  Map<String, int> bought = const {},
}) {
  var current = 0, best = 0, stock = 0, sinceEarn = 0;
  final frozen = <String>[], earned = <String>[];
  final end = DateTime(today.year, today.month, today.day);
  for (
    var d = DateTime(first.year, first.month, first.day);
    !d.isAfter(end);
    d = DateTime(d.year, d.month, d.day + 1)
  ) {
    final key = petDay(d);
    stock = math.min(PetRules.maxFreezes, stock + (bought[key] ?? 0));
    final counted = (minutes[key] ?? 0) >= PetRules.streakMinutes;
    if (counted) {
      current++;
      sinceEarn++;
      if (sinceEarn >= PetRules.freezeEvery) {
        sinceEarn = 0;
        if (stock < PetRules.maxFreezes) {
          stock++;
          earned.add(key);
        }
      }
    } else if (d == end) {
      // Today can still be read; the streak stays as it is.
    } else if (stock > 0 && current > 0) {
      stock--;
      frozen.add(key);
    } else {
      current = 0;
      sinceEarn = 0;
    }
    best = math.max(best, current);
  }
  return StreakState(
    current: current,
    best: best,
    freezes: stock,
    frozenDays: frozen,
    earnedOn: earned,
  );
}

String petDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
