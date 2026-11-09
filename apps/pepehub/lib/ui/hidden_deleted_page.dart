import 'package:flutter/material.dart';

import '../audio/audio_book_actions.dart';
import '../library/book_trash.dart';
import '../library/hidden_files.dart';
import '../library/library_service.dart';
import '../library/models.dart';
import '../reader/reading_book_actions.dart';
import 'app_theme.dart';
import 'audio_mini_player.dart';
import 'audio_roots_page.dart';
import 'book_delete_dialog.dart';
import 'library_card_actions.dart';
import 'reading_roots_page.dart';
import '../diagnostics/user_message.dart';

/// One row of the trash: a removed book/audiobook or a library card.
class _TrashRow {
  final String key, title, subtitle;
  final bool audio;
  final TrashedBook? book;
  final LibraryEntry? card;
  const _TrashRow(
    this.key,
    this.title,
    this.subtitle, {
    required this.audio,
    this.book,
    this.card,
  });
}

String _date(DateTime? value) => value == null
    ? 'дата неизвестна'
    : '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';

/// «Скрытые и недоступные»: hidden books, books whose file is gone, cards
/// without a file, and the single trash for books, audiobooks and library
/// cards.
class HiddenDeletedPage extends StatefulWidget {
  final LibraryService library;

  /// Opening section; null opens the first one that has something.
  final int? initialTab;
  final String initialMedia;
  const HiddenDeletedPage({
    super.key,
    required this.library,
    this.initialTab,
    this.initialMedia = 'all',
  });
  @override
  State<HiddenDeletedPage> createState() => _HiddenDeletedPageState();
}

class _HiddenDeletedPageState extends State<HiddenDeletedPage> {
  static const _tabs = ['Скрытые', 'Файл не найден', 'Без файла', 'Корзина'];
  List<HiddenFile> files = [];
  List<TrashedBook> trashBooks = [];
  List<LibraryEntry> trashCards = [];
  final selected = <String>{};
  final search = TextEditingController();
  late int tab = widget.initialTab ?? 0;
  String query = '';
  late String media = widget.initialMedia;
  String? error;
  bool loading = true, _working = false, _deleting = false;
  bool get busy => _working || _deleting;
  int retention = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  BookTrash get _bookTrash => BookTrash(widget.library.local);

  Future<void> _load() async {
    try {
      final values = await hiddenFiles(widget.library.local);
      final books = await _bookTrash.list();
      final days = await _bookTrash.retentionDays();
      await widget.library.loadCached();
      if (!mounted) return;
      setState(() {
        files = values;
        trashBooks = books;
        trashCards = widget.library.trash.toList()
          ..sort(
            (a, b) => '${b.item.values['pepehub_deleted_at']}'.compareTo(
              '${a.item.values['pepehub_deleted_at']}',
            ),
          );
        retention = days;
        if (loading && widget.initialTab == null && _count(tab) == 0) {
          tab = [0, 1, 2, 3].firstWhere((i) => _count(i) > 0, orElse: () => 0);
        }
        loading = false;
        error = null;
        selected.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = describeError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      _working = true;
      error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = readingBookActionMessage(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  int _count(int index) => index == 3
      ? _trashRows(filter: false).length
      : files.where((f) => f.tab == index && _media(f.audio)).length;

  bool _media(bool audio) => media == 'all' || (media == 'audio') == audio;
  bool _matches(String text, bool audio) =>
      _media(audio) && text.toLowerCase().contains(query.trim().toLowerCase());

  List<HiddenFile> get visibleFiles =>
      files.where((f) => f.tab == tab && _matches(f.title, f.audio)).toList();

  List<_TrashRow> _trashRows({bool filter = true}) {
    final rows = <_TrashRow>[
      for (final book in trashBooks)
        _TrashRow(
          'book:${book.id}',
          book.title,
          '${book.audio ? 'Аудиокнига' : 'Книга'} · удалена ${_date(book.removedAt?.toLocal())}'
              '${book.hasSource ? '' : ' · файла нет'}',
          audio: book.audio,
          book: book,
        ),
      for (final card in trashCards)
        _TrashRow(
          'card:${card.item.id}',
          card.item.title,
          'Карточка библиотеки${card.item.authors.isEmpty ? '' : ' · ${card.item.authors}'} · удалена '
              '${_date(DateTime.tryParse('${card.item.values['pepehub_deleted_at']}')?.toLocal())}',
          audio: card.item.mediaType == 'audiobook',
          card: card,
        ),
    ];
    return rows
        .where(
          (row) => filter
              ? _matches('${row.title} ${row.subtitle}', row.audio)
              : _media(row.audio),
        )
        .toList();
  }

  // ---- Hidden / missing / no file ----

  Future<void> _unhide(List<HiddenFile> targets) => _run(() async {
    final assets = widget.library.assets;
    if (assets == null) throw StateError('Хранилище файлов недоступно');
    await assets.repository.db.transaction(() async {
      await ReadingBookActions(assets).hideMany(
        targets.where((f) => !f.audio).map((f) => f.id),
        hidden: false,
      );
      await AudioBookActions(
        assets,
      ).hideMany(targets.where((f) => f.audio).map((f) => f.id), hidden: false);
    });
  });

  Future<void> _deleteFiles(List<HiddenFile> targets) async {
    final assets = widget.library.assets;
    if (busy || targets.isEmpty || assets == null) return;
    // No progress bar: the deletion dialog opens first.
    setState(() => _deleting = true);
    List<String> moved = const [];
    try {
      moved = await deleteBooksToTrash(context, assets, [
        for (final file in targets)
          (
            id: file.id,
            title: file.title,
            audio: file.audio,
            hasFile: file.hasSource,
          ),
      ]);
    } catch (e) {
      if (mounted) error = readingBookActionMessage(e);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    await _load();
    if (mounted) showMovedToTrash(context, assets, moved, onRestored: _load);
  }

  // ---- Trash ----

  Future<void> _restoreTrash(List<_TrashRow> rows) => _run(() async {
    await _bookTrash.restore([
      for (final row in rows)
        if (row.book case final book?) book.id,
    ]);
    final cards = [
      for (final row in rows)
        if (row.card case final card?) card.item.id,
    ];
    if (cards.isNotEmpty) await widget.library.restoreCards(cards);
  });

  Future<void> _purgeTrash(List<_TrashRow> rows) async {
    if (busy || rows.isEmpty) return;
    final books = [for (final row in rows) ?row.book];
    final cards = [
      for (final row in rows)
        if (row.card case final card?) card.item.id,
    ];
    if (books.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(
            books.length == 1
                ? 'Удалить «${books.single.title}» навсегда?'
                : 'Удалить навсегда книги из корзины (${books.length})?',
          ),
          content: const Text(
            'Прогресс, заметки, закладки и история чтения этих книг будут '
            'удалены без возможности вернуть. Файлы на устройстве не трогаются.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              key: const ValueKey('purge-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить навсегда'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await _run(() => _bookTrash.purge(books.map((b) => b.id)));
    }
    if (cards.isNotEmpty && mounted) {
      setState(() => _deleting = true);
      try {
        final removed = await deleteLibraryCards(
          context,
          widget.library,
          cards,
          fromTrash: true,
          allowFileDeletion: cards.length == 1,
        );
        if (removed && mounted) await _load();
      } finally {
        if (mounted) setState(() => _deleting = false);
      }
    }
  }

  Future<void> _retention(int days) => _run(() async {
    await _bookTrash.setRetention(days);
    await widget.library.setTrashRetention(days);
  });

  Future<void> _folders(bool audio) async {
    final assets = widget.library.assets;
    if (assets == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => audio
            ? AudioRootsPage(assets: assets)
            : ReadingRootsPage(assets: assets),
      ),
    );
    if (mounted) await _load();
  }

  void _toggle(String id) => setState(() {
    if (!selected.remove(id)) selected.add(id);
  });

  String get _hint => switch (tab) {
    0 =>
      'Книги, скрытые с полки. Файлы, прогресс и заметки на месте — '
          'верните книгу, когда понадобится.',
    1 =>
      'При последней проверке файл не нашёлся. Если он переехал, '
          'подключите папку заново или обновите её — книга вернётся сама.',
    2 =>
      'Карточки, созданные вручную, для которых на этом устройстве нет файла.',
    _ =>
      retention == 0
          ? 'Удалённые книги, аудиокниги и карточки библиотеки. Отсюда их '
                'можно вернуть со всей историей.'
          : 'Удалённые книги, аудиокниги и карточки библиотеки. Через '
                '$retention дней они удаляются навсегда.',
  };

  @override
  Widget build(BuildContext context) {
    final colors = PepeColors.of(context);
    final fileRows = tab == 3 ? const <HiddenFile>[] : visibleFiles;
    final trashRows = tab == 3 ? _trashRows() : const <_TrashRow>[];
    final ids = tab == 3
        ? [for (final row in trashRows) row.key]
        : [for (final file in fileRows) file.id];
    final targetIds = selected.isEmpty
        ? ids
        : ids.where(selected.contains).toList();
    final targetFiles = fileRows
        .where((f) => targetIds.contains(f.id))
        .toList();
    final targetTrash = trashRows
        .where((r) => targetIds.contains(r.key))
        .toList();
    final scope = selected.isEmpty ? 'все' : 'выбранные (${targetIds.length})';
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Скрытые и недоступные')),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: CustomScrollView(
          key: ValueKey('hidden-list:$tab'),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (loading || _working) const LinearProgressIndicator(),
                  Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.line)),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          for (var i = 0; i < _tabs.length; i++)
                            InkWell(
                              key: ValueKey('hidden-tab:$i'),
                              onTap: () => setState(() {
                                tab = i;
                                selected.clear();
                              }),
                              child: Container(
                                height: 46,
                                margin: const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      width: 3,
                                      color: tab == i
                                          ? colors.accent
                                          : Colors.transparent,
                                    ),
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${_tabs[i]} ${_count(i)}',
                                  style: TextStyle(
                                    fontWeight: tab == i
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: tab == i ? null : colors.muted,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(_hint, style: TextStyle(color: colors.muted)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: search,
                          decoration: const InputDecoration(
                            hintText: 'Поиск по названию',
                            prefixIcon: Icon(Icons.search),
                            filled: true,
                          ),
                          onChanged: (v) => setState(() {
                            query = v;
                            selected.clear();
                          }),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final (value, label) in const [
                              ('all', 'Все'),
                              ('book', 'Книги'),
                              ('audio', 'Аудиокниги'),
                            ])
                              ChoiceChip(
                                label: Text(label),
                                selected: media == value,
                                onSelected: busy
                                    ? null
                                    : (_) => setState(() {
                                        media = value;
                                        selected.clear();
                                      }),
                              ),
                          ],
                        ),
                        if (tab == 3)
                          DropdownButton<int>(
                            key: const ValueKey('trash-retention'),
                            isExpanded: true,
                            value:
                                BookTrash.retentionChoices.contains(retention)
                                ? retention
                                : 30,
                            items: [
                              for (final days in BookTrash.retentionChoices)
                                DropdownMenuItem(
                                  value: days,
                                  child: Text(
                                    days == 0
                                        ? 'Хранить в корзине, пока не очищу'
                                        : 'Хранить в корзине $days дней',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) {
                                    if (v != null && v != retention) {
                                      _retention(v);
                                    }
                                  },
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (ids.isNotEmpty)
                          Wrap(
                            spacing: 4,
                            children: [
                              if (tab == 0 || tab == 3)
                                TextButton.icon(
                                  key: const ValueKey('hidden-restore'),
                                  onPressed: busy
                                      ? null
                                      : tab == 3
                                      ? () => _restoreTrash(targetTrash)
                                      : () => _unhide(targetFiles),
                                  icon: const Icon(Icons.restore, size: 18),
                                  label: Text('Вернуть $scope'),
                                ),
                              TextButton.icon(
                                key: const ValueKey('hidden-delete'),
                                style: TextButton.styleFrom(
                                  foregroundColor: tab == 3
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                ),
                                onPressed: busy
                                    ? null
                                    : tab == 3
                                    ? () => _purgeTrash(targetTrash)
                                    : () => _deleteFiles(targetFiles),
                                icon: Icon(
                                  tab == 3
                                      ? Icons.delete_forever
                                      : Icons.delete_outline,
                                  size: 18,
                                ),
                                label: Text(
                                  tab == 3
                                      ? selected.isEmpty
                                            ? 'Очистить корзину'
                                            : 'Удалить навсегда $scope'
                                      : 'Удалить $scope…',
                                ),
                              ),
                              if (selected.isNotEmpty)
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => setState(selected.clear),
                                  child: const Text('Снять выбор'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (ids.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: loading
                    ? const SizedBox.shrink()
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            query.isNotEmpty
                                ? 'Ничего не найдено'
                                : switch (tab) {
                                    0 => 'Скрытых книг нет',
                                    1 => 'Все файлы на месте',
                                    2 => 'Карточек без файла нет',
                                    _ => 'Корзина пуста',
                                  },
                            style: TextStyle(color: colors.muted),
                          ),
                        ),
                      ),
              )
            else
              SliverList.builder(
                itemCount: ids.length,
                itemBuilder: (context, index) {
                  final id = ids[index];
                  final row = tab == 3 ? trashRows[index] : null;
                  final file = tab == 3 ? null : fileRows[index];
                  final audio = row?.audio ?? file!.audio;
                  return ListTile(
                    key: ValueKey('hidden-row:${file?.id ?? id}'),
                    selected: selected.contains(id),
                    onLongPress: busy ? null : () => _toggle(id),
                    onTap: selected.isEmpty || busy ? null : () => _toggle(id),
                    leading: selected.isNotEmpty
                        ? Checkbox(
                            value: selected.contains(id),
                            onChanged: busy ? null : (_) => _toggle(id),
                          )
                        : Icon(
                            row?.card != null
                                ? Icons.style_outlined
                                : audio
                                ? Icons.headphones_outlined
                                : Icons.menu_book_outlined,
                            color: colors.muted,
                          ),
                    title: Text(row?.title ?? file!.title),
                    subtitle: Text(
                      row?.subtitle ??
                          (audio ? 'Аудиокнига' : 'Книга') +
                              (file!.hasSource ? '' : ' · файла нет'),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tab == 0 || tab == 3)
                          IconButton(
                            tooltip: tab == 3 ? 'Вернуть' : 'Вернуть на полку',
                            onPressed: busy
                                ? null
                                : tab == 3
                                ? () => _restoreTrash([row!])
                                : () => _unhide([file!]),
                            icon: const Icon(Icons.restore),
                          )
                        else
                          IconButton(
                            tooltip: 'Папки',
                            onPressed: busy ? null : () => _folders(audio),
                            icon: const Icon(Icons.folder_open),
                          ),
                        IconButton(
                          tooltip: tab == 3 ? 'Удалить навсегда' : 'Удалить…',
                          onPressed: busy
                              ? null
                              : tab == 3
                              ? () => _purgeTrash([row!])
                              : () => _deleteFiles([file!]),
                          icon: Icon(
                            tab == 3
                                ? Icons.delete_forever
                                : Icons.delete_outline,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
