import 'package:flutter/material.dart';

import '../library/library_features.dart';
import '../library/library_service.dart';
import '../library/metadata_values.dart';
import '../library/models.dart';
import 'library_work_page.dart';
import 'library_series_editor_page.dart';
import 'library_archive_page.dart' show metadataSeriesListeningLabel;

class LibraryGroupsPage extends StatefulWidget {
  final LibraryService library;
  final String kind;
  final String? name;
  final String? seriesKey;
  const LibraryGroupsPage({
    super.key,
    required this.library,
    required this.kind,
    this.name,
    this.seriesKey,
  });
  @override
  State<LibraryGroupsPage> createState() => _LibraryGroupsPageState();
}

class _LibraryGroupsPageState extends State<LibraryGroupsPage> {
  int expected = 0;
  String? currentSeriesKey;
  String get selectedSeriesKey =>
      currentSeriesKey ??
      widget.seriesKey ??
      'series:${seriesTextKey(widget.name)}';
  String get key =>
      'library-series-length:${selectedSeriesKey.startsWith('series-id:') ? selectedSeriesKey : widget.name?.trim().toLowerCase()}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = int.tryParse(await widget.library.local.meta(key) ?? '') ?? 0;
    if (mounted) setState(() => expected = value.clamp(0, 500));
  }

  Iterable<String> groups(LibraryEntry e) => widget.kind == 'author'
      ? metadataStrings(e.item.value('author'))
      : widget.kind == 'collection'
      ? libraryCollections(e.item)
      : metadataStrings(e.item.value('series'));
  Future<void> _length() async {
    final input = TextEditingController(text: expected == 0 ? '' : '$expected');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Сколько томов в серии?'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            helperText: 'От 1 до 500. Пусто — число томов неизвестно.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final n = input.text.isEmpty ? 0 : int.tryParse(input.text);
              if (n != null && n >= 0 && n <= 500) Navigator.pop(context, n);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null) {
      await widget.library.local.setMeta(key, '$value');
      if (mounted) setState(() => expected = value);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.library,
    builder: (context, _) {
      final all = widget.kind == 'series'
          ? widget.library.seriesEntries
          : widget.library.visibleEntries;
      final seriesGroups = widget.kind == 'series'
          ? {
              for (final g in groupLibrarySeries(all))
                if (g.name.isNotEmpty) g.key: g,
            }
          : <String, LibrarySeriesGroup>{};
      final names = <String, String>{};
      if (widget.kind == 'series') {
        names.addAll({
          for (final g in seriesGroups.entries) g.key: g.value.name,
        });
      } else {
        for (final e in all) {
          for (final name in groups(e)) {
            names.putIfAbsent(name.trim().toLowerCase(), () => name);
          }
        }
      }
      final list = all
          .where(
            (e) => widget.kind == 'series'
                ? librarySeriesKey(e.item) == selectedSeriesKey
                : groups(e).any(
                    (name) =>
                        name.trim().toLowerCase() ==
                        widget.name?.trim().toLowerCase(),
                  ),
          )
          .toList();
      num index(LibraryEntry e) {
        final n = num.tryParse('${e.item.value('seriesIndex')}');
        return n?.isFinite == true ? n! : 0;
      }

      list.sort(
        (a, b) => widget.kind == 'series'
            ? index(a).compareTo(index(b))
            : a.item.title.compareTo(b.item.title),
      );
      final finished = list
          .where((e) => libraryStatus(e.item) == 'finished')
          .length;
      final known = list
          .map(index)
          .where((n) => n >= 1 && n <= 500 && n == n.round())
          .map((n) => n.toInt())
          .toSet();
      final maxKnown = known.fold<int>(0, (a, b) => a > b ? a : b);
      final upper = expected > maxKnown ? expected : maxKnown;
      final rows = <({LibraryEntry? entry, int? missing})>[];
      if (widget.kind == 'series') {
        rows.addAll(list.map((e) => (entry: e, missing: null)));
        for (var n = 1; n <= upper; n++) {
          if (!known.contains(n)) {
            rows.add((entry: null, missing: n));
          }
        }
        num? rowIndex(({LibraryEntry? entry, int? missing}) row) {
          final n =
              row.missing ??
              num.tryParse('${row.entry!.item.value('seriesIndex')}');
          return n?.isFinite == true ? n : null;
        }

        rows.sort((a, b) {
          final left = rowIndex(a), right = rowIndex(b);
          if (left == null) return right == null ? 0 : 1;
          return right == null ? -1 : left.compareTo(right);
        });
      } else {
        rows.addAll(list.map((e) => (entry: e, missing: null)));
      }
      double fraction(LibraryEntry e) {
        if (isUnreadSeriesItem(e.item)) return 0;
        if (libraryStatus(e.item) == 'finished') return 1;
        final total = num.tryParse('${e.item.value('total')}'),
            progress = num.tryParse('${e.item.value('progress')}');
        return total != null &&
                total.isFinite &&
                total > 0 &&
                progress != null &&
                progress.isFinite
            ? (progress / total).clamp(0.0, 1.0)
            : 0;
      }

      final progress = list.isEmpty
          ? 0.0
          : list.fold<double>(0, (sum, e) => sum + fraction(e)) / list.length;
      Widget tile(LibraryEntry e) => ListTile(
        leading: Icon(
          libraryStatus(e.item) == 'finished'
              ? Icons.check_circle_outline
              : e.item.mediaType == 'audiobook'
              ? Icons.headphones
              : Icons.menu_book_outlined,
        ),
        title: Text(
          '${widget.kind == 'series' && index(e) > 0 ? 'Том ${index(e)} · ' : ''}${e.item.title}',
        ),
        subtitle: Text(
          '${e.item.authors}\n${libraryItemStatuses(e.item)[libraryStatus(e.item)] ?? 'Статус не указан'} · ${e.item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга'}',
        ),
        isThreeLine: true,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                LibraryWorkPage(library: widget.library, itemId: e.item.id),
          ),
        ),
      );
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.name ??
                (widget.kind == 'author'
                    ? 'Авторы'
                    : widget.kind == 'series'
                    ? 'Серии'
                    : 'Коллекции'),
          ),
        ),
        body: Builder(
          builder: (context) {
            final orderedNames = names.entries.toList()
              ..sort(
                (a, b) =>
                    a.value.toLowerCase().compareTo(b.value.toLowerCase()),
              );
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(
                    child: widget.name == null
                        ? names.isEmpty
                              ? const Text(
                                  'Пока нет записей. Заполните сведения в карточках книг.',
                                )
                              : const SizedBox.shrink()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Завершено $finished из ${list.length} · книги и аудиокниги',
                              ),
                              Text(
                                'Общий прогресс: ${(progress * 100).round()}%',
                              ),
                              if (widget.kind == 'series' &&
                                  list.any(
                                    (e) => e.item.mediaType == 'audiobook',
                                  ))
                                Text(
                                  metadataSeriesListeningLabel(
                                    LibrarySeriesGroup(
                                      widget.name!,
                                      selectedSeriesKey,
                                      list,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(value: progress),
                              if (widget.kind == 'series') ...[
                                TextButton.icon(
                                  onPressed: list.isEmpty
                                      ? null
                                      : () async {
                                          final memberId = list.first.item.id;
                                          await openLibrarySeriesEditor(
                                            context,
                                            widget.library,
                                            series:
                                                seriesGroups[selectedSeriesKey] ??
                                                LibrarySeriesGroup(
                                                  widget.name!,
                                                  selectedSeriesKey,
                                                  list,
                                                ),
                                          );
                                          if (!mounted) return;
                                          final member = widget.library.entries
                                              .where(
                                                (e) => e.item.id == memberId,
                                              )
                                              .firstOrNull;
                                          if (member != null) {
                                            setState(
                                              () => currentSeriesKey =
                                                  librarySeriesKey(member.item),
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.playlist_add),
                                  label: const Text('Добавить тома'),
                                ),
                                TextButton(
                                  onPressed: _length,
                                  child: Text(
                                    expected == 0
                                        ? 'Указать число томов'
                                        : 'Всего томов: $expected',
                                  ),
                                ),
                                const Text(
                                  'Пропуски определяются по номерам сохранённых томов и указанному размеру серии.',
                                ),
                              ],
                              const SizedBox(height: 16),
                            ],
                          ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  sliver: SliverList.builder(
                    itemCount: widget.name == null
                        ? orderedNames.length
                        : rows.length,
                    itemBuilder: (context, index) {
                      if (widget.name == null) {
                        final group = orderedNames[index];
                        return ListTile(
                          title: Text(group.value),
                          subtitle: widget.kind == 'series'
                              ? Text(
                                  seriesGroups[group.key]!
                                      .entries
                                      .first
                                      .item
                                      .authors,
                                )
                              : null,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LibraryGroupsPage(
                                library: widget.library,
                                kind: widget.kind,
                                name: group.value,
                                seriesKey: widget.kind == 'series'
                                    ? group.key
                                    : null,
                              ),
                            ),
                          ),
                        );
                      }
                      final row = rows[index];
                      return row.entry != null
                          ? tile(row.entry!)
                          : ListTile(
                              leading: const Icon(Icons.remove_circle_outline),
                              title: Text(
                                'Том ${row.missing} — нет в библиотеке',
                              ),
                            );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}
