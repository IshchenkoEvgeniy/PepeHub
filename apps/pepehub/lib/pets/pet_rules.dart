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

  /// Level of the growth path choice.
  static const pathLevel = 25;

  /// One talent point per this many levels (20 points by level 100).
  static const talentEvery = 5;

  /// Experience needed to go from [level] to the next one. About 81 000 to
  /// level 100: some 3.5 years at an hour a day, level 70 in about 1.5.
  static int xpForLevel(int level) => (25 + 2 * math.pow(level, 1.5)).round();

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

  // ------------------------------------------------ sleep and mood (no penalty)

  /// The pet's day: awake from [wakeHour] to [sleepHour], asleep at night.
  static const wakeHour = 7, sleepHour = 23;

  /// Energy left by bedtime and restored by the morning.
  static const tiredEnergy = 0.2;

  /// Energy 0..1 on a pet clock: full at 7:00, falls to [tiredEnergy] by
  /// 23:00, rises back while asleep. With the light turned off early
  /// ([lightsOff] … [lightsUntil]) the pet sleeps and recovers from then on.
  static double energy(DateTime now, {DateTime? lightsOff, DateTime? lightsUntil}) {
    final h = now.hour + now.minute / 60;
    double awake(double hour) =>
        1 - (1 - tiredEnergy) * ((hour - wakeHour) / (sleepHour - wakeHour));
    if (lightsOff != null &&
        lightsUntil != null &&
        !now.isBefore(lightsOff) &&
        now.isBefore(lightsUntil)) {
      final lh = lightsOff.hour + lightsOff.minute / 60;
      final start = lh >= wakeHour && lh < sleepHour ? awake(lh) : tiredEnergy;
      final t = now.difference(lightsOff).inMinutes /
          math.max(1, lightsUntil.difference(lightsOff).inMinutes);
      return (start + (1 - start) * t).clamp(0, 1).toDouble();
    }
    if (h >= wakeHour && h < sleepHour) return awake(h).clamp(0, 1).toDouble();
    // Night: from 23:00 to 7:00 (8 hours) back to full.
    final slept = h >= sleepHour ? h - sleepHour : h + 24 - sleepHour;
    return (tiredEnergy + (1 - tiredEnergy) * slept / (24 - sleepHour + wakeHour))
        .clamp(0, 1)
        .toDouble();
  }

  /// Night hours or the light turned off early.
  static bool asleep(DateTime now, {DateTime? lightsOff, DateTime? lightsUntil}) {
    if (lightsOff != null &&
        lightsUntil != null &&
        !now.isBefore(lightsOff) &&
        now.isBefore(lightsUntil)) {
      return true;
    }
    return now.hour >= sleepHour || now.hour < wakeHour;
  }

  /// The next morning [wakeHour] after [now].
  static DateTime nextMorning(DateTime now) {
    final today = DateTime(now.year, now.month, now.day, wakeHour);
    return now.isBefore(today) ? today : today.add(const Duration(days: 1));
  }

  /// Hours for mood to fall from full to zero without attention.
  static const moodHours = 36;

  /// Mood of a pet nobody has played with yet.
  static const moodDefault = 0.6;

  /// Mood 0..1: [value] set at [at], slowly fading.
  static double mood(double? value, DateTime? at, DateTime now) {
    if (value == null || at == null) return moodDefault;
    final hours = now.difference(at).inMinutes / 60;
    return (value - hours / moodHours).clamp(0, 1).toDouble();
  }

  /// Mood gains: a game, a stroke, a treat, ordinary food.
  static const moodPlay = 0.2, moodPet = 0.06, moodTreat = 0.3, moodFood = 0.1;

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
