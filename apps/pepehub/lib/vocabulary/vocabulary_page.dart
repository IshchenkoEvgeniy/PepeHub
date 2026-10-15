import 'package:flutter/material.dart';

import '../ui/pepe_widgets.dart';
import 'anki_export.dart';
import 'vocabulary_editor.dart';
import 'vocabulary_repository.dart';

typedef AnkiExporter = Future<bool> Function(List<VocabularyCard> cards);

class VocabularyPage extends StatefulWidget {
  final VocabularyRepository repository;
  final AnkiExporter export;
  const VocabularyPage({
    super.key,
    required this.repository,
    this.export = saveAnkiExport,
  });
  @override
  State<VocabularyPage> createState() => _VocabularyPageState();
}

class _VocabularyPageState extends State<VocabularyPage> {
  List<VocabularyCard> cards = [];
  final selected = <String>{};
  String query = '';
  VocabularyKind? kind;
  bool loading = true, busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await widget.repository.list();
      if (mounted) {
        setState(() {
          cards = next;
          loading = false;
          error = null;
          selected.retainAll(next.map((c) => c.id));
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _edit([VocabularyCard? card]) async {
    final saved = await Navigator.push<VocabularyCard>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            VocabularyEditorPage(repository: widget.repository, existing: card),
      ),
    );
    if (saved != null && mounted) await _load();
  }

  Future<void> _delete(VocabularyCard card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить карточку?'),
        content: Text(card.front),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.repository.delete(card);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _help() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Импорт в Anki'),
      content: const SingleChildScrollView(
        child: Text(
          '1. Экспортируйте карточки в файл .txt.\n\n'
          '2. В Anki на компьютере выберите «Импортировать файл» и тип заметки «Обычный» / Basic с двумя полями.\n\n'
          '3. Проверьте: Front → лицевая сторона, Back → обратная. Теги, колода и HTML заданы в заголовке файла. Контекст и источник добавлены к ответу.\n\n'
          '4. Синхронизируйте Anki, чтобы получить карточки на телефоне.\n\n'
          'Anki сравнивает заметки по лицевой стороне. Повторный импорт может обновить ответ; для одинаковых фраз проверьте обработку дубликатов в окне импорта. Изменение самой фразы может создать новую заметку.\n\n'
          'Карточки остаются в PepeHub после экспорта. Аудио и кадры в этот текстовый экспорт не входят.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );

  Future<void> _export(List<VocabularyCard> visible) async {
    final batch = selected.isEmpty
        ? visible
        : cards.where((c) => selected.contains(c.id)).toList();
    if (busy || batch.isEmpty) return;
    final duplicates = batch.length != batch.map((c) => c.front).toSet().length;
    if (duplicates) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Есть одинаковые фразы'),
          content: const Text(
            'Anki может считать их одной заметкой. В окне импорта разрешите добавление дубликатов, если нужны все варианты.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Экспортировать'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() => busy = true);
    try {
      final saved = await widget.export(List.unmodifiable(batch));
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Экспортировано карточек: ${batch.length}. В Anki выберите тип «Обычный» / Basic.',
            ),
            action: SnackBarAction(
              label: 'Как импортировать',
              onPressed: _help,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Экспорт не завершён: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final search = query.trim().toLowerCase();
    final visible = cards
        .where(
          (c) =>
              (kind == null || c.kind == kind) &&
              '${c.front} ${c.back} ${c.context} ${c.deck} ${c.tags.join(' ')} ${c.source?.label ?? ''}'
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    return PepeSubpage(
      title: 'Словарь Anki',
      actions: [
        IconButton(
          tooltip: 'Импорт в Anki',
          onPressed: _help,
          icon: const Icon(Icons.help_outline),
        ),
        IconButton(
          tooltip: 'Новая карточка Anki',
          onPressed: busy ? null : () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                TextField(
                  key: const ValueKey('vocabulary-search'),
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    hintText: 'Поиск слов, фраз и источников',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('Все'),
                      selected: kind == null,
                      onSelected: (_) => setState(() => kind = null),
                    ),
                    ChoiceChip(
                      label: const Text('Слова'),
                      selected: kind == VocabularyKind.word,
                      onSelected: (_) =>
                          setState(() => kind = VocabularyKind.word),
                    ),
                    ChoiceChip(
                      label: const Text('Предложения'),
                      selected: kind == VocabularyKind.sentence,
                      onSelected: (_) =>
                          setState(() => kind = VocabularyKind.sentence),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        selected.isEmpty
                            ? '${visible.length} карточек'
                            : 'Выбрано: ${selected.length}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (selected.isNotEmpty)
                      IconButton(
                        tooltip: 'Снять выбор',
                        onPressed: busy ? null : () => setState(selected.clear),
                        icon: const Icon(Icons.deselect),
                      ),
                    FilledButton.icon(
                      key: const ValueKey('vocabulary-export'),
                      onPressed: busy || (visible.isEmpty && selected.isEmpty)
                          ? null
                          : () => _export(visible),
                      icon: const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('Экспорт'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        cards.isEmpty
                            ? 'Добавьте слово или предложение. В видео карточку можно создать из меню плеера или расшифровки.'
                            : 'По этому фильтру карточек нет.',
                      ),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final card = visible[index];
                        return ListTile(
                          key: ValueKey('vocabulary-card-${card.id}'),
                          leading: Checkbox(
                            value: selected.contains(card.id),
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      selected.add(card.id);
                                    } else {
                                      selected.remove(card.id);
                                    }
                                  }),
                          ),
                          title: Text(
                            card.front,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${card.back}\n${card.source?.label ?? card.deck}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          onTap: busy ? null : () => _edit(card),
                          trailing: PopupMenuButton<String>(
                            enabled: !busy,
                            tooltip: 'Действия с карточкой',
                            onSelected: (value) =>
                                value == 'edit' ? _edit(card) : _delete(card),
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Редактировать'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Удалить'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
