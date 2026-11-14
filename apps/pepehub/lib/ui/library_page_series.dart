part of 'library_page.dart';

/// One row of the «Серии» shelf view: a series header or a book card.
/// [indent] marks a volume shown under its expanded series.
sealed class _ShelfRow {
  const _ShelfRow();
}

class _BookRow extends _ShelfRow {
  final LibraryRecord book;
  final bool indent;
  const _BookRow(this.book, {this.indent = false});
}

class _SeriesRow extends _ShelfRow {
  final String key, name;
  final List<LibraryRecord> volumes;
  const _SeriesRow(this.key, this.name, this.volumes);
}

/// Series of shelf books: grouping, ordering by volume number and the
/// collapsible header. Read-only: a library card is consulted for its series
/// but never created or changed here.
extension _LibraryPageSeries on _LibraryPageState {
  /// The library card's series wins over the file metadata, so a series
  /// corrected in «Библиотека» is used on the shelf as well.
  ({String name, double? number})? _seriesOf(LibraryRecord b) {
    final card = personalLibrary.forBook(b.id)?.item;
    final cardName = '${card?.value('series') ?? ''}'.trim();
    if (cardName.isNotEmpty) {
      return (
        name: cardName,
        number: _seriesNumber(card!.value('seriesIndex')),
      );
    }
    final info = b.payload!['format'] == 'audio' ? b.payload! : _textInfo(b);
    final name = '${info['series'] ?? ''}'.trim();
    if (name.isEmpty) return null;
    return (
      name: name,
      number: _seriesNumber(info['seriesNumber'] ?? info['seriesIndex']),
    );
  }

  static double? _seriesNumber(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse('${value ?? ''}'.trim().replaceAll(',', '.'));

  String _seriesLabel(LibraryRecord b) {
    final series = _seriesOf(b);
    if (series == null) return '';
    final number = series.number;
    if (number == null) return series.name;
    final text = number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
    return '${series.name} · $text';
  }

  /// «По серии»: books without a series last, then series by name and
  /// volume number.
  int _compareSeries(LibraryRecord a, LibraryRecord b) {
    final sa = _seriesOf(a), sb = _seriesOf(b);
    if ((sa == null) != (sb == null)) return sa == null ? 1 : -1;
    if (sa == null || sb == null) return 0;
    final byName = naturalAudioOrder(sa.name, sb.name);
    return byName != 0 ? byName : _compareVolumes(a, b);
  }

  int _compareVolumes(LibraryRecord a, LibraryRecord b) {
    final na = _seriesOf(a)?.number, nb = _seriesOf(b)?.number;
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    if ((na == null) != (nb == null)) return na == null ? 1 : -1;
    return naturalAudioOrder(_title(a), _title(b));
  }

  /// Series keep the place of their first volume in the chosen sort; books
  /// without a series stay where they are. A series with one volume on the
  /// shelf is shown as its card: a header would only add a tap.
  List<_ShelfRow> _seriesRows(List<LibraryRecord> listed) {
    final groups = <String, List<LibraryRecord>>{};
    final names = <String, String>{};
    final order = <Object>[];
    for (final book in listed) {
      final series = _seriesOf(book);
      if (series == null) {
        order.add(book);
        continue;
      }
      final key = series.name.toLowerCase();
      final group = groups[key];
      if (group == null) {
        groups[key] = [book];
        names[key] = series.name;
        order.add(key);
      } else {
        group.add(book);
      }
    }
    final rows = <_ShelfRow>[];
    for (final item in order) {
      if (item is LibraryRecord) {
        rows.add(_BookRow(item));
        continue;
      }
      final key = item as String;
      final volumes = groups[key]!..sort(_compareVolumes);
      if (volumes.length == 1) {
        rows.add(_BookRow(volumes.single));
        continue;
      }
      rows.add(_SeriesRow(key, names[key]!, volumes));
      if (expandedSeries.contains(key)) {
        rows.addAll(volumes.map((b) => _BookRow(b, indent: true)));
      }
    }
    return rows;
  }

  bool _isDone(LibraryRecord b) => _status(b) == 'finished';

  Widget _seriesHeader(_SeriesRow row) {
    final scheme = Theme.of(context).colorScheme;
    final expanded = expandedSeries.contains(row.key);
    final done = row.volumes.where(_isDone).length;
    // The cover of the volume to read next; the last one when all are done.
    final next = row.volumes.firstWhere(
      (b) => !_isDone(b),
      orElse: () => row.volumes.last,
    );
    final authors = {
      for (final b in row.volumes)
        for (final a in _authors(b).split(', '))
          if (a.trim().isNotEmpty) a.trim(),
    };
    final selectedCount = row.volumes
        .where((b) => selectedBooks.contains(b.id))
        .length;
    return Material(
      key: ValueKey('series-row:${row.key}'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy
            ? null
            : selectionMode
            ? () => _update(() {
                final all = selectedCount == row.volumes.length;
                for (final b in row.volumes) {
                  if (all) {
                    selectedBooks.remove(b.id);
                  } else {
                    selectedBooks.add(b.id);
                  }
                }
              })
            : () => _update(() {
                if (!expandedSeries.remove(row.key)) {
                  expandedSeries.add(row.key);
                }
              }),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              SizedBox(
                width: 54,
                height: 81,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: _shelfCover(next),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.collections_bookmark_outlined,
                          size: 16,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            row.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (authors.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          authors.take(3).join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      selectionMode
                          ? 'Выбрано $selectedCount из ${row.volumes.length}'
                          : '${reading ? 'Прочитано' : 'Прослушано'} $done из ${row.volumes.length}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: done / row.volumes.length,
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selectionMode
                    ? selectedCount == row.volumes.length
                          ? Icons.check_box
                          : selectedCount == 0
                          ? Icons.check_box_outline_blank
                          : Icons.indeterminate_check_box
                    : expanded
                    ? Icons.expand_less
                    : Icons.expand_more,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The «Серии» view: series headers and cards, built lazily.
  Widget _seriesSliver(List<LibraryRecord> listed) {
    final rows = _seriesRows(listed);
    return SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: switch (rows[i]) {
          _SeriesRow row => _seriesHeader(row),
          _BookRow(:final book, :final indent) =>
            indent
                ? Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: _bookCard(book),
                  )
                : _bookCard(book),
        },
      ),
    );
  }
}
