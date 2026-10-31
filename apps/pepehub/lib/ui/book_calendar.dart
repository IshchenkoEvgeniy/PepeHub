import 'package:flutter/material.dart';

import '../library/book_calendar_data.dart';
import '../library/library_service.dart';
import '../library/reading_insights.dart';
import 'audio_cover.dart';
import 'library_work_page.dart';
import 'obsidian_library_dashboard.dart' show ShelfBookCover;

class BookCalendar extends StatefulWidget {
  final int year;
  final String scope;
  final BookCalendarData data;
  final LibraryService? library;
  const BookCalendar({
    super.key,
    required this.year,
    required this.scope,
    required this.data,
    this.library,
  });
  @override
  State<BookCalendar> createState() => _BookCalendarState();
}

class _BookCalendarState extends State<BookCalendar> {
  int month = DateTime.now().month;
  String? selected;
  @override
  void didUpdateWidget(BookCalendar old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year || old.scope != widget.scope) selected = null;
  }

  Map<String, int> _books(String day) => {
    for (final e in (widget.data.days[day] ?? <String, int>{}).entries)
      if (widget.scope == 'all' ||
          widget.data.books[e.key]?.mediaType ==
              (widget.scope == 'audio' ? 'audiobook' : 'book'))
        e.key: e.value,
  };

  Widget _cover(CalendarBook? book, {double width = 32, double height = 46}) {
    if (book == null) return const Icon(Icons.menu_book_outlined);
    final assets = widget.library?.assets;
    if (book.entry == null && book.mediaType == 'audiobook' && assets != null) {
      return SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: AudioCover(assets: assets, bookId: book.id),
        ),
      );
    }
    return ShelfBookCover(
      title: book.title,
      mediaType: book.mediaType,
      cover: '${book.entry?.item.value('cover') ?? ''}',
      localPath: book.localCover,
      width: width,
      height: height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(widget.year, month);
    final length = DateTime(widget.year, month + 1, 0).day;
    final offset = first.weekday - 1;
    final cells = ((length + offset + 6) ~/ 7) * 7;
    String key(int day) =>
        '${widget.year}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
    final selectedBooks = selected == null
        ? <String, int>{}
        : _books(selected!);
    final entries = selectedBooks.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final monthDays = widget.data.days.keys
        .where(
          (d) => d.startsWith(key(1).substring(0, 7)) && _books(d).isNotEmpty,
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${bookMonths[month - 1]} ${widget.year}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Предыдущий месяц',
              onPressed: month == 1
                  ? null
                  : () => setState(() {
                      month--;
                      selected = null;
                    }),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              onPressed: month == 12
                  ? null
                  : () => setState(() {
                      month++;
                      selected = null;
                    }),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Text(
          'Дней с книгой: $monthDays · выберите день, чтобы увидеть подробности',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final day in const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
              Expanded(
                child: Center(
                  child: Text(
                    day,
                    style: TextStyle(
                      color: day == 'Вс'
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 600;
            return GridView.builder(
              key: ValueKey('book-calendar:${widget.year}:$month'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: cells,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: wide ? 130 : 96,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemBuilder: (_, index) {
                final day = index - offset + 1;
                if (day < 1 || day > length) return const SizedBox.shrink();
                final date = key(day), books = _books(key(day));
                final ranked = books.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value));
                final today = DateUtils.isSameDay(
                  DateTime(widget.year, month, day),
                  DateTime.now(),
                );
                return Semantics(
                  button: true,
                  label: '${bookDateLabel(date)}, книг: ${books.length}',
                  child: Material(
                    color: selected == date
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(
                        color: today ? scheme.primary : Colors.transparent,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => setState(() => selected = date),
                      child: Column(
                        children: [
                          Text(
                            '$day',
                            style: TextStyle(
                              fontSize: 12,
                              color: index % 7 == 6 ? scheme.error : null,
                            ),
                          ),
                          Expanded(
                            child: ranked.isEmpty
                                ? const SizedBox.shrink()
                                : Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      _cover(
                                        widget.data.books[ranked.first.key],
                                        width: wide ? 56 : 32,
                                        height: wide ? 82 : 48,
                                      ),
                                      if (ranked.length > 1)
                                        Positioned(
                                          right: 1,
                                          bottom: 0,
                                          child: Container(
                                            color: scheme.surface,
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 3,
                                            ),
                                            child: Text(
                                              '+${ranked.length - 1}',
                                              style: const TextStyle(
                                                fontSize: 10,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                          if (books.isNotEmpty)
                            Text(
                              books.values.any((v) => v > 0)
                                  ? bookActivityTime(
                                      books.values.fold<int>(
                                        0,
                                        (a, b) => a + b,
                                      ),
                                    )
                                  : '✓',
                              maxLines: 1,
                              style: const TextStyle(fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
        if (selected != null) ...[
          const SizedBox(height: 12),
          Text(
            bookDateLabel(selected),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('В этот день записей нет.'),
            ),
          // Bound the inline preview; the full day list is built lazily in a sheet.
          for (final e in entries.take(3)) _dayBook(e),
          if (entries.length > 3)
            TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => SizedBox(
                  height: MediaQuery.sizeOf(context).height * .7,
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (_, i) => _dayBook(entries[i]),
                  ),
                ),
              ),
              child: Text('Все книги за день · ${entries.length}'),
            ),
        ],
      ],
    );
  }

  Widget _dayBook(MapEntry<String, int> e) {
    final book = widget.data.books[e.key];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _cover(book),
      title: Text(book?.title ?? 'Книга без файла'),
      subtitle: Text(
        '${e.value > 0 ? bookActivityTime(e.value) : 'Время не записано'} · ${book?.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга'}${widget.data.completedDays[selected]?.contains(e.key) == true ? ' · завершено' : ''}',
      ),
      onTap: book?.entry == null || widget.library == null
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LibraryWorkPage(
                  library: widget.library!,
                  itemId: book!.entry!.item.id,
                ),
              ),
            ),
    );
  }
}
