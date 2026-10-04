import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../reader/reading_library.dart';
import 'reading_statistics_page.dart';
import 'reading_plan_page.dart';

class ReadingBookPage extends StatefulWidget {
  final Repository repository;
  final LibraryRecord book;
  final LocalAsset? asset;
  final AssetStore? assets;
  const ReadingBookPage({
    super.key,
    required this.repository,
    required this.book,
    this.asset,
    this.assets,
  });
  @override
  State<ReadingBookPage> createState() => _ReadingBookPageState();
}

class _ReadingBookPageState extends State<ReadingBookPage> {
  late final library = ReadingLibrary(widget.repository);
  final title = TextEditingController(),
      authors = TextEditingController(),
      series = TextEditingController(),
      number = TextEditingController(),
      description = TextEditingController();
  String? cover, started, finished, error;
  String status = 'planned';
  Uint8List? pickedCover;
  bool loading = true, saving = false;
  bool startEdited = false, endEdited = false, statusEdited = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [title, authors, series, number, description]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await library.bookInfo(widget.book, widget.asset?.hash);
      final prefs = await library.value('reading-book:${widget.book.id}');
      final overrides = prefs['overrides'] as Map? ?? {};
      if (!mounted) return;
      setState(() {
        title.text = info['title'] as String? ?? widget.book.title;
        authors.text = (info['authors'] as List? ?? []).join('; ');
        series.text = info['series'] as String? ?? '';
        number.text = '${info['seriesNumber'] ?? ''}';
        description.text = info['description'] as String? ?? '';
        cover = info['cover'] as String?;
        started = info['startedAt'] as String?;
        finished = info['finishedAt'] as String?;
        status = info['status'] as String? ?? 'planned';
        startEdited = overrides.containsKey('startedAt');
        endEdited = overrides.containsKey('finishedAt');
        statusEdited = overrides.containsKey('status');
        loading = false;
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

  Future<void> _cover() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Обложка',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
            mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Изображение больше 8 МиБ');
      }
      final codec = await ui.instantiateImageCodec(
        await file.readAsBytes(),
        targetWidth: 600,
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (mounted) setState(() => pickedCover = data!.buffer.asUint8List());
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Обложка не выбрана: $e');
    }
  }

  Future<void> _date(bool first) async {
    final previous = DateTime.tryParse((first ? started : finished) ?? '')
        ?.toLocal();
    final date = await showDatePicker(
      context: context,
      initialDate: previous ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) {
      setState(() {
        if (first) {
          startEdited = true;
          started = date.toIso8601String();
        } else {
          endEdited = true;
          finished = date.toIso8601String();
        }
      });
    }
  }

  Future<void> _save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (pickedCover != null && widget.assets != null) {
        final directory = Directory(
          p.join(widget.assets!.directory.path, 'reading-covers'),
        );
        await directory.create(recursive: true);
        final file = File(
          p.join(directory.path, 'manual-${sha256.convert(pickedCover!)}.png'),
        );
        await file.writeAsBytes(pickedCover!, flush: true);
        cover = file.path;
      }
      await library.saveDetails(widget.book.id, {
        'title': title.text,
        'authors': authors.text
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        'series': series.text.trim(),
        'seriesNumber': number.text.trim(),
        'description': description.text.trim(),
        'cover': cover,
        if (startEdited) 'startedAt': started,
        if (endEdited) 'finishedAt': finished,
        if (statusEdited) 'status': status,
      });
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _label(String? value) {
    final d = DateTime.tryParse(value ?? '')?.toLocal();
    return d == null ? 'Не указана' : '${d.day}.${d.month}.${d.year}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Карточка книги'),
      actions: [
        IconButton(
          tooltip: 'План чтения',
          icon: const Icon(Icons.event_note),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReadingPlanPage(
                repository: widget.repository,
                bookId: widget.book.id,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Статистика книги',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReadingStatisticsPage(
                repository: widget.repository,
                bookId: widget.book.id,
              ),
            ),
          ),
          icon: const Icon(Icons.bar_chart),
        ),
      ],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : AbsorbPointer(
            absorbing: saving,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: SizedBox(
                    width: 130,
                    height: 185,
                    child: pickedCover != null
                        ? Image.memory(pickedCover!, fit: BoxFit.cover)
                        : cover != null
                        ? Image.file(
                            File(cover!),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.menu_book, size: 64),
                          )
                        : const Icon(Icons.menu_book, size: 64),
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      onPressed: widget.assets == null ? null : _cover,
                      child: const Text('Выбрать обложку'),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          cover = null;
                          pickedCover = null;
                        });
                      },
                      child: const Text('Убрать обложку'),
                    ),
                  ],
                ),
                for (final entry in [
                  (title, 'Название'),
                  (authors, 'Авторы через ;'),
                  (series, 'Серия'),
                  (number, 'Номер в серии'),
                  (description, 'Описание'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextField(
                      controller: entry.$1,
                      maxLength: entry.$1 == description ? 10000 : 500,
                      maxLines: entry.$1 == description ? 5 : 1,
                      decoration: InputDecoration(labelText: entry.$2),
                    ),
                  ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Статус'),
                  items: const [
                    DropdownMenuItem(value: 'planned', child: Text('Новая')),
                    DropdownMenuItem(value: 'active', child: Text('Читаю')),
                    DropdownMenuItem(
                      value: 'finished',
                      child: Text('Завершена'),
                    ),
                  ],
                  onChanged: (v) => setState(() {
                    status = v!;
                    statusEdited = true;
                  }),
                ),
                for (final first in [true, false])
                  ListTile(
                    title: Text(first ? 'Начало чтения' : 'Завершение чтения'),
                    subtitle: Text(_label(first ? started : finished)),
                    onTap: () => _date(first),
                    trailing: IconButton(
                      tooltip: 'Очистить дату',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        if (first) {
                          started = null;
                          startEdited = true;
                        } else {
                          finished = null;
                          endEdited = true;
                        }
                      }),
                    ),
                  ),
                const Text(
                  'Ручные сведения сохраняются при повторном сканировании файла.',
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _save,
                  child: Text(saving ? 'Сохранение…' : 'Сохранить карточку'),
                ),
              ],
            ),
          ),
  );
}
