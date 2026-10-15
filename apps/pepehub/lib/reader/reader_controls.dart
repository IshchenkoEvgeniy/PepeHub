import 'dart:async';

import 'package:flutter/material.dart';

import 'reader_layout.dart';
import 'reader_search.dart';

Future<ReaderPreferences?> showReaderSettings(
  BuildContext context,
  ReaderPreferences initial,
) => showModalBottomSheet<ReaderPreferences>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) {
    var value = initial;
    return StatefulBuilder(
      builder: (context, setState) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Оформление чтения',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: value.font,
                decoration: const InputDecoration(labelText: 'Шрифт'),
                items: const [
                  DropdownMenuItem(
                    value: 'serif',
                    child: Text('Lora · с засечками'),
                  ),
                  DropdownMenuItem(
                    value: 'sans',
                    child: Text('Системный · без засечек'),
                  ),
                ],
                onChanged: (v) => setState(() => value = value.copy(font: v)),
              ),
              Text('Размер шрифта: ${value.size.round()}'),
              Slider(
                value: value.size,
                min: 12,
                max: 56,
                divisions: 44,
                label: '${value.size.round()}',
                onChanged: (v) => setState(() => value = value.copy(size: v)),
              ),
              Text(
                'Высота страницы: ${(value.pageHeightFactor * 100).round()}% экрана',
              ),
              Slider(
                value: value.pageHeightFactor,
                min: .65,
                max: 1.5,
                divisions: 17,
                label: '${(value.pageHeightFactor * 100).round()}%',
                onChanged: (v) =>
                    setState(() => value = value.copy(pageHeightFactor: v)),
              ),
              const Text(
                'Для непрерывного чтения. В режиме без пустых мест меняет длину фрагментов.',
              ),
              Text('Межстрочный интервал: ${value.spacing.toStringAsFixed(1)}'),
              Slider(
                value: value.spacing,
                min: 1.2,
                max: 2.2,
                divisions: 10,
                onChanged: (v) =>
                    setState(() => value = value.copy(spacing: v)),
              ),
              Text('Поля: ${value.margin.round()}'),
              Slider(
                value: value.margin,
                min: 12,
                max: 48,
                divisions: 9,
                onChanged: (v) => setState(() => value = value.copy(margin: v)),
              ),
              Text('Ширина колонки: ${value.columnWidth.round()}'),
              Slider(
                key: const ValueKey('reader-column-width'),
                value: value.columnWidth,
                min: 360,
                max: 1200,
                divisions: 21,
                onChanged: (v) =>
                    setState(() => value = value.copy(columnWidth: v)),
              ),
              const Text(
                'Ограничение ширины на ПК. На телефоне колонка подстраивается под экран.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in {
                    'light': 'Светлая',
                    'dark': 'Тёмная',
                    'sepia': 'Сепия',
                    'system': 'Как в системе',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: value.palette == entry.key,
                      onSelected: (_) => setState(
                        () => value = value.copy(palette: entry.key),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in {
                    'seamless': 'Непрерывно',
                    'compact': 'Без пустых мест',
                    'pages': 'Перелистывание',
                    'scroll': 'По главам',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: value.mode == entry.key,
                      onSelected: (_) =>
                          setState(() => value = value.copy(mode: entry.key)),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Показывать полосу прокрутки'),
                subtitle: const Text('По умолчанию полоса скрыта'),
                value: value.showScrollbar,
                onChanged: (v) =>
                    setState(() => value = value.copy(showScrollbar: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Показывать выделения'),
                subtitle: const Text(
                  'Цитаты и заметки сохраняются при скрытии',
                ),
                value: value.showHighlights,
                onChanged: (v) =>
                    setState(() => value = value.copy(showHighlights: v)),
              ),
              const SizedBox(height: 16),
              const Text('Зоны нажатия: слева · центр · справа'),
              for (final zone in ['left', 'center', 'right'])
                DropdownButtonFormField<String>(
                  initialValue: zone == 'left'
                      ? value.leftTap
                      : zone == 'right'
                      ? value.rightTap
                      : value.centerTap,
                  decoration: InputDecoration(
                    labelText: zone == 'left'
                        ? 'Левая зона'
                        : zone == 'right'
                        ? 'Правая зона'
                        : 'Центральная зона',
                  ),
                  items: [
                    for (final entry in {
                      'previous': 'Назад',
                      'next': 'Вперёд',
                      'controls': 'Показать / скрыть панели',
                      'none': 'Ничего',
                    }.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (v) => setState(
                    () => value = value.copy(
                      leftTap: zone == 'left' ? v : null,
                      rightTap: zone == 'right' ? v : null,
                      centerTap: zone == 'center' ? v : null,
                    ),
                  ),
                ),
              Text('Ширина боковых зон: ${(value.zoneWidth * 100).round()}%'),
              Slider(
                value: value.zoneWidth,
                min: .15,
                max: .4,
                divisions: 5,
                onChanged: (v) =>
                    setState(() => value = value.copy(zoneWidth: v)),
              ),
              const Text(
                'Долгое нажатие выделяет текст. Кнопка выхода из полного экрана остаётся доступной.',
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: value.margin,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: value.isDark(MediaQuery.platformBrightnessOf(context))
                      ? const Color(0xff20262a)
                      : value.palette == 'sepia'
                      ? const Color(0xfff3e8d0)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Книга открывает мир — строка за строкой.',
                  style: value.style(
                    value.isDark(MediaQuery.platformBrightnessOf(context))
                        ? const Color(0xffdedbd3)
                        : const Color(0xff302b24),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, value),
                  child: const Text('Применить'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  },
);

class ReaderSearch extends StatefulWidget {
  final ReaderDocument document;
  final int currentChapter;
  final ReaderSearchSession? session;
  const ReaderSearch({
    super.key,
    required this.document,
    this.currentChapter = 0,
    this.session,
  });
  @override
  State<ReaderSearch> createState() => _ReaderSearchState();
}

class _ReaderSearchState extends State<ReaderSearch> {
  final worker = ReaderSearchWorker();
  late final ReaderSearchSession session =
      widget.session ?? ReaderSearchSession();
  late final controller = TextEditingController(text: session.query);
  Timer? debounce;
  int generation = 0;
  bool busy = false;
  String error = '';
  List<Map<String, dynamic>> results = [];
  bool hasMore = false;
  int? get scope => session.inCurrentChapter ? widget.currentChapter : null;

  @override
  void initState() {
    super.initState();
    if (session.complete && session.scannedChapter == scope) {
      results = session.hits;
      hasMore = session.hasMore;
    } else {
      _changed(controller.text);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    worker.cancel();
    controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    debounce?.cancel();
    worker.cancel();
    final token = ++generation;
    setState(() {
      session.query = text;
      session.complete = text.trim().isEmpty;
      session.hits = results = [];
      session.hasMore = hasMore = false;
      session.scannedChapter = scope;
      busy = text.trim().isNotEmpty;
      error = '';
    });
    if (!busy) return;
    debounce = Timer(const Duration(milliseconds: 250), () => _scan(token));
  }

  Future<void> _scan(int token, {bool more = false}) async {
    try {
      final next = await worker.search(
        texts: widget.document.texts,
        query: session.query,
        chapter: scope,
        after: more && results.isNotEmpty ? results.last : null,
      );
      if (!mounted || generation != token || next == null) return;
      setState(() {
        results = List.unmodifiable([if (more) ...results, ...next.hits]);
        hasMore = next.hasMore;
        session.hits = results;
        session.hasMore = hasMore;
        session.complete = true;
        session.scannedChapter = scope;
      });
    } catch (e) {
      if (mounted && generation == token) {
        setState(() => error = 'Не удалось выполнить поиск: $e');
      }
    } finally {
      if (mounted && generation == token) setState(() => busy = false);
    }
  }

  void _more() {
    if (busy || !hasMore) return;
    setState(() {
      busy = true;
      error = '';
    });
    _scan(generation, more: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Поиск по книге')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: _changed,
                  decoration: InputDecoration(
                    hintText: 'Слово или фраза',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              controller.clear();
                              _changed('');
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Вся книга'),
                      selected: !session.inCurrentChapter,
                      onSelected: (_) {
                        session.inCurrentChapter = false;
                        _changed(controller.text);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Текущая глава'),
                      selected: session.inCurrentChapter,
                      onSelected: (_) {
                        session.inCurrentChapter = true;
                        _changed(controller.text);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(error)),
          if (session.query.trim().isNotEmpty && (!busy || results.isNotEmpty))
            Text(
              results.isEmpty
                  ? 'Ничего не найдено'
                  : 'Совпадений: ${results.length}${hasMore ? '+' : ''}',
            ),
          Expanded(
            child: ListView.builder(
              itemCount: results.length + (hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == results.length) {
                  return TextButton.icon(
                    onPressed: busy ? null : _more,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Показать ещё совпадения'),
                  );
                }
                final hit = results[i];
                return ListTile(
                  title: Text(
                    widget.document.book.chapters[hit['chapter'] as int].title,
                  ),
                  subtitle: Text(hit['excerpt'] as String),
                  onTap: () => Navigator.pop(context, hit),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
