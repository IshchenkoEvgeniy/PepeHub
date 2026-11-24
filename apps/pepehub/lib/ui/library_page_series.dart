part of 'library_page.dart';

/// One row of the shelf grouped by series: a series header or a book card.
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

  /// The volume to read next; the last one when all are done.
  LibraryRecord _nextVolume(_SeriesRow row) => row.volumes.firstWhere(
    (b) => !_isDone(b),
    orElse: () => row.volumes.last,
  );

  /// A tap on a series expands it, or selects all its volumes while choosing.
  VoidCallback? _seriesTap(_SeriesRow row) {
    if (busy) return null;
    if (selectionMode) {
      return () => _update(() {
        final all = row.volumes.every((b) => selectedBooks.contains(b.id));
        for (final b in row.volumes) {
          if (all) {
            selectedBooks.remove(b.id);
          } else {
            selectedBooks.add(b.id);
          }
        }
      });
    }
    return () => _update(() {
      if (!expandedSeries.remove(row.key)) expandedSeries.add(row.key);
    });
  }

  IconData _seriesStateIcon(_SeriesRow row, int selectedCount) => selectionMode
      ? selectedCount == row.volumes.length
            ? Icons.check_box
            : selectedCount == 0
            ? Icons.check_box_outline_blank
            : Icons.indeterminate_check_box
      : expandedSeries.contains(row.key)
      ? Icons.expand_less
      : Icons.expand_more;

  Widget _seriesHeader(_SeriesRow row) {
    final scheme = Theme.of(context).colorScheme;
    final done = row.volumes.where(_isDone).length;
    final next = _nextVolume(row);
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
        onTap: _seriesTap(row),
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
                _seriesStateIcon(row, selectedCount),
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A series among the covers: the next volume's cover with the covers of
  /// the following ones peeking out behind it, then the name and progress.
  /// Expanded volumes follow it as ordinary tiles.
  Widget _seriesTile(_SeriesRow row, double width) {
    final colors = PepeColors.of(context);
    final audio = !reading;
    final done = row.volumes.where(_isDone).length;
    final next = _nextVolume(row);
    final behind = row.volumes.where((b) => b != next).take(2).toList();
    final selectedCount = row.volumes
        .where((b) => selectedBooks.contains(b.id))
        .length;
    final coverHeight = width * (audio ? 1 : 1.5);
    const peek = 6.0;
    final authors = {
      for (final b in row.volumes)
        for (final a in _authors(b).split(', '))
          if (a.trim().isNotEmpty) a.trim(),
    };
    Widget cover(LibraryRecord book) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: _shelfCover(book),
    );
    return Material(
      key: ValueKey('series-row:${row.key}'),
      color: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _seriesTap(row),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Color.lerp(colors.surface, colors.text, .06)!,
                  ),
                  for (var i = behind.length - 1; i >= 0; i--)
                    Positioned(
                      top: 8 + peek * (i + 1),
                      bottom: 8,
                      left: 14 + peek * (i + 1) * 2,
                      right: 14 - peek * (i + 1) * 2,
                      child: Opacity(
                        opacity: .55 - i * .15,
                        child: cover(behind[i]),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    bottom: 8 + peek * behind.length,
                    left: 14,
                    right: 14 + peek * behind.length * 2,
                    child: cover(next),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        child: Text(
                          '${row.volumes.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: done / row.volumes.length,
                      minHeight: 4,
                      color: colors.accent,
                      backgroundColor: Colors.black.withValues(alpha: .4),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 4),
                          child: Icon(
                            Icons.collections_bookmark_outlined,
                            size: 15,
                            color: colors.accent,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.book(colors.text, size: 15),
                          ),
                        ),
                      ],
                    ),
                    if (authors.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          authors.take(2).join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            selectionMode
                                ? 'Выбрано $selectedCount из ${row.volumes.length}'
                                : '${reading ? 'Прочитано' : 'Прослушано'} $done из ${row.volumes.length}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: colors.muted),
                          ),
                        ),
                        Icon(
                          _seriesStateIcon(row, selectedCount),
                          size: 20,
                          color: colors.muted,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The list grouped by series: headers and cards, built lazily.
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
