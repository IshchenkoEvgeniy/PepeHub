/// Small labels shown on text-book cards in the «Книги» shelf.
library;

/// Minimum evidence before a reading speed is trusted (matches reading plans).
const minimumSpeedSampleMs = 60000, minimumSpeedSampleChars = 300;

/// Characters per minute from a speed sample, or null when it is too small.
double? readingRate(int activeMs, int chars) =>
    activeMs >= minimumSpeedSampleMs && chars >= minimumSpeedSampleChars
    ? chars * 60000 / activeMs
    : null;

String readingDuration(int minutes) => minutes >= 60
    ? '${minutes ~/ 60} ч${minutes % 60 == 0 ? '' : ' ${minutes % 60} мин'}'
    : '${minutes < 1 ? 1 : minutes} мин';

/// «Осталось ≈ 2 ч 10 мин» for a started book, «≈ 6 ч чтения» for a new one.
///
/// [length] is the text length in characters and [rate] characters per minute.
String? textRemainingLabel({
  required int length,
  required double fraction,
  required double? rate,
}) {
  if (length <= 0 || rate == null || rate <= 0 || fraction >= 1) return null;
  final started = fraction > 0;
  final remaining = length * (1 - fraction.clamp(0.0, 1.0));
  final minutes = (remaining / rate).ceil();
  return started
      ? 'Осталось ≈ ${readingDuration(minutes)}'
      : '≈ ${readingDuration(minutes)} чтения';
}

const _months = [
  'янв.',
  'февр.',
  'мар.',
  'апр.',
  'мая',
  'июня',
  'июля',
  'авг.',
  'сент.',
  'окт.',
  'нояб.',
  'дек.',
];

/// Calendar date in the reader's words: «сегодня», «вчера», «3 нояб.».
String shelfDay(DateTime value, DateTime now) {
  final local = value.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'сегодня';
  if (days == 1) return 'вчера';
  final date = '${local.day} ${_months[local.month - 1]}';
  return local.year == now.year ? date : '$date ${local.year}';
}

/// «открыта вчера» from a stored ISO timestamp; null when unknown.
String? lastOpenedLabel(Object? updatedAt, DateTime now) {
  final value = updatedAt is String ? DateTime.tryParse(updatedAt) : null;
  if (value == null) return null;
  return 'открыта ${shelfDay(value, now)}';
}
