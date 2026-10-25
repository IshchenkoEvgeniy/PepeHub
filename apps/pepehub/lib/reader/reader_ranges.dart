/// Immutable interval index. Query cost depends on nearby overlapping ranges,
/// rather than every annotation/footnote in a whole book.
class ReaderRangeIndex<T> {
  final int Function(T) start, end;
  final List<({T value, int order})> _ordered;
  final List<int> _maxEnd = [];

  ReaderRangeIndex(List<T> values, {required this.start, required this.end})
    : _ordered = [
        for (var i = 0; i < values.length; i++) (value: values[i], order: i),
      ] {
    _ordered.sort((a, b) {
      final difference = start(a.value).compareTo(start(b.value));
      return difference == 0 ? a.order.compareTo(b.order) : difference;
    });
    var maximum = -1;
    for (final entry in _ordered) {
      final limit = end(entry.value);
      if (limit > maximum) maximum = limit;
      _maxEnd.add(maximum);
    }
  }

  List<T> overlapping(int from, int to) {
    if (to <= from) return [];
    var low = 0, high = _maxEnd.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_maxEnd[middle] > from) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    final hits = <({T value, int order})>[];
    for (var i = low; i < _ordered.length; i++) {
      final entry = _ordered[i];
      if (start(entry.value) >= to) break;
      if (end(entry.value) > from) hits.add(entry);
    }
    // Preserve source precedence for coincident/overlapping footnotes.
    hits.sort((a, b) => a.order.compareTo(b.order));
    return [for (final entry in hits) entry.value];
  }
}
