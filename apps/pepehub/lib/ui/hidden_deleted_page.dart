import 'package:flutter/material.dart';

import '../audio/audio_book_actions.dart';
import '../library/hidden_files.dart';
import '../library/library_service.dart';
import '../library/models.dart';
import '../reader/reading_book_actions.dart';
import 'audio_roots_page.dart';
import 'reading_roots_page.dart';
import 'audio_mini_player.dart';
import 'library_card_actions.dart';

class HiddenDeletedPage extends StatefulWidget {
  final LibraryService library;
  final int initialTab;
  final String initialMedia;
  const HiddenDeletedPage({
    super.key,
    required this.library,
    this.initialTab = 0,
    this.initialMedia = 'all',
  });
  @override
  State<HiddenDeletedPage> createState() => _HiddenDeletedPageState();
}

class _HiddenDeletedPageState extends State<HiddenDeletedPage> {
  List<HiddenFile> files = [];
  List<LibraryEntry> trash = [];
  final selected = <String>{};
  final search = TextEditingController();
  late int tab = widget.initialTab;
  String query = '';
  late String media = widget.initialMedia;
  String? error;
  bool loading = true, _working = false, _removing = false;
  bool get busy => _working || _removing;
  int retention = 0;
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

  Future<void> _load() async {
    try {
      final values = await hiddenFiles(widget.library.local);
      await widget.library.loadCached();
      final days =
          int.tryParse(
            await widget.library.local.meta('library-trash-retention-days') ??
                '',
          ) ??
          0;
      if (!mounted) return;
      setState(() {
        files = values;
        trash = widget.library.trash.toList()
          ..sort(
            (a, b) => '${b.item.values['pepehub_deleted_at']}'.compareTo(
              '${a.item.values['pepehub_deleted_at']}',
            ),
          );
        retention = [7, 30, 90].contains(days) ? days : 0;
        loading = false;
        error = null;
        selected.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
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
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  List<HiddenFile> get visibleFiles =>
      files.where((f) => f.tab == tab && _matches(f.title, f.audio)).toList();
  List<LibraryEntry> get visibleTrash => trash
      .where(
        (c) => _matches(
          '${c.item.title} ${c.item.authors}',
          c.item.mediaType == 'audiobook',
        ),
      )
      .toList();
  bool _matches(String text, bool audio) =>
      text.toLowerCase().contains(query.trim().toLowerCase()) &&
      (media == 'all' || (media == 'audio') == audio);
  List<String> get visibleIds => tab == 3
      ? visibleTrash.map((c) => c.item.id).toList()
      : visibleFiles.map((f) => f.id).toList();
  Future<void> _restore(List<String> ids) => _run(() async {
    if (tab == 3) {
      await widget.library.restoreCards(ids);
      return;
    }
    final assets = widget.library.assets;
    if (assets == null) throw StateError('Хранилище файлов недоступно');
    final chosen = ids.toSet();
    final targets = files.where((f) => chosen.contains(f.id)).toList();
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
  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _purge(List<String> ids, {bool withFiles = false}) async {
    if (busy) return;
    setState(() => _removing = true);
    try {
      final removed = await deleteLibraryCards(
        context,
        widget.library,
        ids,
        fromTrash: true,
        allowFileDeletion: withFiles,
      );
      if (removed && mounted) await _load();
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Future<void> _retention(int days) async {
    if (days != 0 &&
        !await _confirm(
          'Включить автоочистку?',
          'Карточки, находящиеся в корзине дольше $days дней, будут удаляться вместе с их цитатами и журналом библиотеки при открытии приложения или библиотеки. Уже просроченные карточки будут удалены сейчас.',
        )) {
      return;
    }
    await _run(() => widget.library.setTrashRetention(days));
  }

  void _toggle(String id, bool? value) => setState(() {
    if (value == true) {
      selected.add(id);
    } else {
      selected.remove(id);
    }
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

  @override
  Widget build(BuildContext context) {
    final fileRows = visibleFiles;
    final trashRows = visibleTrash;
    final ids = tab == 3
        ? trashRows.map((c) => c.item.id).toList()
        : fileRows.map((f) => f.id).toList();
    final emptyLabel = tab == 3 && trash.isEmpty
        ? 'Корзина пуста'
        : tab == 0 && !files.any((f) => f.tab == 0)
        ? 'Убранных книг нет'
        : 'Ничего не найдено';
    final targets = selected.isEmpty
        ? ids
        : ids.where(selected.contains).toList();
    return PopScope(
      canPop: !busy,
      child: DefaultTabController(
        length: 4,
        initialIndex: tab,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Скрытое и отсутствующее'),
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              onTap: (value) => setState(() {
                tab = value;
                selected.clear();
              }),
              tabs: const [
                Tab(text: 'Убранные'),
                Tab(text: 'Файл исчез'),
                Tab(text: 'Без файла'),
                Tab(text: 'Корзина'),
              ],
            ),
          ),
          bottomNavigationBar: const AudioPlayerFooter(),
          body: CustomScrollView(
            key: ValueKey('hidden-list:$tab'),
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (loading || _working) const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: search,
                            decoration: const InputDecoration(
                              labelText: 'Поиск',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (v) => setState(() {
                              query = v;
                              selected.clear();
                            }),
                          ),
                          DropdownButton<String>(
                            value: media,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('Книги и аудиокниги'),
                              ),
                              DropdownMenuItem(
                                value: 'book',
                                child: Text('Книги'),
                              ),
                              DropdownMenuItem(
                                value: 'audio',
                                child: Text('Аудиокниги'),
                              ),
                            ],
                            onChanged: busy
                                ? null
                                : (v) => setState(() {
                                    media = v!;
                                    selected.clear();
                                  }),
                          ),
                          if (tab == 3)
                            DropdownButton<int>(
                              value: retention,
                              isExpanded: true,
                              items: [
                                for (final days in [0, 7, 30, 90])
                                  DropdownMenuItem(
                                    value: days,
                                    child: Text(
                                      days == 0
                                          ? 'Автоочистка выключена'
                                          : 'Удалять через $days дней',
                                    ),
                                  ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (v) {
                                      if (v != null) _retention(v);
                                    },
                            ),
                          Text(switch (tab) {
                            0 => 'Убранные из списка файлов книги. Прогресс и заметки сохранены.',
                            1 => 'Файл не найден при последней проверке. Подключите папку заново или обновите её.',
                            2 => 'Для этих записей нет локального источника. Подключите соответствующую папку или добавьте файл.',
                            _ => 'Корзина карточек библиотеки. Исходные файлы не удаляются.',
                          }),
                          if (error != null)
                            Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          Wrap(
                            spacing: 8,
                            children: [
                              if (tab == 0 || tab == 3) ...[
                                TextButton(
                                  onPressed: busy || ids.isEmpty
                                      ? null
                                      : () => setState(() {
                                          selected
                                            ..clear()
                                            ..addAll(ids);
                                        }),
                                  child: Text(
                                    'Выбрать найденные (${ids.length})',
                                  ),
                                ),
                                TextButton(
                                  onPressed: busy || targets.isEmpty
                                      ? null
                                      : () => _restore(targets),
                                  child: Text(
                                    selected.isEmpty
                                        ? 'Вернуть все найденные'
                                        : 'Вернуть выбранные (${targets.length})',
                                  ),
                                ),
                              ],
                              if (tab == 3)
                                TextButton(
                                  onPressed: busy || trash.isEmpty
                                      ? null
                                      : () => _purge(
                                          selected.isEmpty
                                              ? trash
                                                    .map((c) => c.item.id)
                                                    .toList()
                                              : targets,
                                        ),
                                  child: Text(
                                    selected.isEmpty
                                        ? 'Очистить корзину'
                                        : 'Удалить выбранные',
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
                      : Center(child: Text(emptyLabel)),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final id = ids[index];
                    final card = tab == 3 ? trashRows[index] : null;
                    final file = tab == 3 ? null : fileRows[index];
                    final deleted = card == null
                        ? null
                        : DateTime.tryParse(
                            '${card.item.values['pepehub_deleted_at']}',
                          )?.toLocal();
                    return ListTile(
                      key: ValueKey('hidden-row:$id'),
                      leading: tab == 0 || tab == 3
                          ? Checkbox(
                              value: selected.contains(id),
                              onChanged: busy ? null : (v) => _toggle(id, v),
                            )
                          : Icon(
                              file!.audio ? Icons.headphones : Icons.menu_book,
                            ),
                      title: Text(card?.item.title ?? file!.title),
                      subtitle: card == null
                          ? null
                          : Text(
                              '${card.item.authors}${deleted == null ? '\nДата удаления неизвестна' : '\nУдалено: ${deleted.day}.${deleted.month}.${deleted.year}'}',
                            ),
                      trailing: tab == 0 || tab == 3
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: tab == 3
                                      ? 'Восстановить'
                                      : 'Вернуть в список',
                                  onPressed: busy ? null : () => _restore([id]),
                                  icon: const Icon(Icons.restore),
                                ),
                                if (tab == 3)
                                  IconButton(
                                    tooltip: 'Удалить окончательно',
                                    onPressed: busy
                                        ? null
                                        : () => _purge([id], withFiles: true),
                                    icon: const Icon(Icons.delete_forever),
                                  ),
                              ],
                            )
                          : IconButton(
                              tooltip: 'Открыть папки',
                              icon: const Icon(Icons.folder_open),
                              onPressed: busy
                                  ? null
                                  : () => _folders(file!.audio),
                            ),
                    );
                  }, childCount: ids.length),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
