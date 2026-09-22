/// Unknown lengths must not turn into zero-length chapters or false percentages.
class BookTimeline {
  final List<int?> lengths;
  BookTimeline(this.lengths);
  int? get totalMs => lengths.isEmpty || lengths.any((d) => d == null || d <= 0)
      ? null
      : lengths.fold<int>(0, (sum, d) => sum + d!);
  int? positionMs(int index, int position) {
    if (index < 0 ||
        index >= lengths.length ||
        lengths.take(index).any((d) => d == null || d <= 0)) {
      return null;
    }
    final limit = lengths[index];
    return lengths.take(index).fold<int>(0, (sum, d) => sum + d!) +
        position.clamp(0, limit ?? position);
  }

  (int, int)? locate(int position) {
    final total = totalMs;
    if (total == null) return null;
    var remaining = position.clamp(0, total);
    for (var i = 0; i < lengths.length; i++) {
      if (remaining < lengths[i]! || i == lengths.length - 1) {
        return (i, remaining);
      }
      remaining -= lengths[i]!;
    }
    return null;
  }
}
