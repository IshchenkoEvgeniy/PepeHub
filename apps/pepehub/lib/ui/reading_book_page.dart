import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../reader/reading_activity.dart';
import '../reader/reading_library.dart';
import '../reader/reading_plan.dart';
import 'audio_statistics_page.dart' show statTime;
import 'pepe_widgets.dart';
import 'reading_plan_page.dart';
import 'reading_statistics_page.dart';
import 'shelf_components.dart';

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
  ReadingPlanData? plan;
  ReadingForecast? _forecast;
  ReadingTotals _totals = ReadingTotals();
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
      ReadingPlanData? planData;
      try {
        planData = await ReadingPlans(widget.repository).load(widget.book.id);
      } catch (_) {
        planData = null;
      }
      final analysis = planData == null
          ? null
          : await analyzeReadingPlan(planData, widget.book.id, DateTime.now());
      if (!mounted) return;
      setState(() {
        _forecast = analysis?.forecast;
        _totals = analysis?.totals ?? ReadingTotals();
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
        plan = planData;
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

  Future<void> _openPlan() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingPlanPage(
          repository: widget.repository,
          bookId: widget.book.id,
        ),
      ),
    );
    if (!mounted) return;
    try {
      final data = await ReadingPlans(widget.repository).load(widget.book.id);
      final analysis = await analyzeReadingPlan(
        data,
        widget.book.id,
        DateTime.now(),
      );
      if (mounted) {
        setState(() {
          plan = data;
          _forecast = analysis.forecast;
          _totals = analysis.totals;
        });
      }
    } catch (_) {}
  }

  void _openStatistics() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReadingStatisticsPage(
        repository: widget.repository,
        bookId: widget.book.id,
      ),
    ),
  );

  Widget _coverImage(ShelfPalette palette, double width) {
    final placeholder = Container(
      color: palette.raised,
      alignment: Alignment.center,
      child: Icon(Icons.menu_book, size: width / 3, color: palette.muted),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: width,
        height: width * 1.45,
        child: pickedCover != null
            ? Image.memory(pickedCover!, fit: BoxFit.cover)
            : cover != null
            ? Image.file(
                File(cover!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              )
            : placeholder,
      ),
    );
  }

  Widget _coverButtons() => Wrap(
    spacing: 4,
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
  );

  Widget _status() => PepeChoices<String>(
    options: const [
      ('planned', 'Новая'),
      ('active', 'Читаю'),
      ('finished', 'Завершена'),
    ],
    selected: status,
    onSelect: (v) => setState(() {
      status = v;
      statusEdited = true;
    }),
  );

  Widget _planPanel(
    ShelfPalette palette,
    ReadingPlanData data,
    ReadingForecast forecast,
  ) {
    final saved = data.saved;
    String date(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    return PepePanel(
      title: 'План чтения',
      trailing: TextButton(
        onPressed: _openPlan,
        child: Text(saved == null ? 'Составить' : 'Изменить'),
      ),
      child: saved == null
          ? Text(
              'Плана пока нет. Задайте минуты в день и срок — приложение посчитает, когда вы закончите.',
              style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
            )
          : Row(
              children: [
                PepeRing(
                  value: forecast.todayMs / (saved.dailyMinutes * 60000),
                  center: '${forecast.todayMs ~/ 60000}',
                  below: 'из ${saved.dailyMinutes} мин',
                  size: 96,
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        forecast.complete
                            ? 'Цель по объёму достигнута'
                            : forecast.remainingMinutes == null
                            ? 'Мало данных для прогноза'
                            : 'Осталось ≈ ${statTime(forecast.remainingMinutes! * 60000)}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        [
                          'цель — первые ${saved.targetPercent}%',
                          if (saved.deadline != null)
                            'срок ${date(saved.deadline!)}',
                          if (forecast.expectedDate != null &&
                              !forecast.complete)
                            'закончите ${date(forecast.expectedDate!)}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12.5, color: palette.muted),
                      ),
                      if (forecast.overdue)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Срок прошёл',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _details(ShelfPalette palette, bool wide) {
    Widget field(TextEditingController controller, String label) => TextField(
      controller: controller,
      maxLength: controller == description ? 10000 : 500,
      maxLines: controller == description ? 5 : 1,
      decoration: InputDecoration(labelText: label),
    );
    Widget pair(Widget a, Widget b) => wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 16),
              Expanded(child: b),
            ],
          )
        : Column(children: [a, const SizedBox(height: 6), b]);
    Widget dateTile(bool first) => Material(
      color: palette.raised,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    );
    return PepePanel(
      title: 'Сведения',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pair(field(title, 'Название'), field(authors, 'Авторы через ;')),
          const SizedBox(height: 6),
          pair(field(series, 'Серия'), field(number, 'Номер в серии')),
          const SizedBox(height: 6),
          field(description, 'Описание'),
          const SizedBox(height: 10),
          pair(dateTile(true), dateTile(false)),
          const SizedBox(height: 12),
          Text(
            'Ручные сведения сохраняются при повторном сканировании файла.',
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _save,
              child: Text(saving ? 'Сохранение…' : 'Сохранить карточку'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final wide = pepeWide(context);
    final data = plan;
    final forecast = _forecast, totals = _totals;
    final now = DateTime.now();
    final fortnight = [
      for (var i = 13; i >= 0; i--) DateTime(now.year, now.month, now.day - i),
    ];
    final covered = data == null || data.length == 0 || forecast == null
        ? null
        : forecast.coveredChars / data.length;
    final authorLine = [
      if (authors.text.trim().isNotEmpty) authors.text.trim(),
      if (series.text.trim().isNotEmpty)
        number.text.trim().isEmpty
            ? series.text.trim()
            : '${series.text.trim()} · №${number.text.trim()}',
    ].join(' · ');

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (authorLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              authorLine,
              style: AppFonts.book(palette.muted, size: wide ? 20 : 16),
            ),
          ),
        _status(),
      ],
    );
    final figures = PepeFigureStrip([
      (
        covered == null ? '—' : '${(covered * 100).toStringAsFixed(0)}%',
        'Прочитано',
      ),
      (pepeTime(totals.milliseconds), 'Всего за книгу'),
      ('${totals.sessions}', 'Сессий'),
      (_label(started), 'Начало чтения'),
    ]);
    final bars = PepePanel(
      title: 'Две недели',
      trailing: IconButton(
        tooltip: 'Статистика книги',
        onPressed: _openStatistics,
        icon: const Icon(Icons.bar_chart),
      ),
      child: PepeBars(
        height: 110,
        values: [for (final d in fortnight) totals.days[readingDay(d)] ?? 0],
        tooltips: [
          for (final d in fortnight)
            '${pepeDate(d)} · ${pepeTime(totals.days[readingDay(d)] ?? 0)}',
        ],
        goalMinutes: data?.saved?.dailyMinutes ?? 0,
        startLabel: pepeDate(fortnight.first),
        endLabel: 'сегодня',
      ),
    );
    final description = this.description.text.trim();
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide) ...[heading, const SizedBox(height: 22)],
        figures,
        if (description.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            description,
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.book(palette.text, size: 16).copyWith(height: 1.55),
          ),
        ],
        const SizedBox(height: 18),
        PepeRow(
          children: [
            if (data != null && forecast != null)
              (5, _planPanel(palette, data, forecast)),
            (6, bars),
          ],
        ),
        const SizedBox(height: 18),
        _details(palette, wide),
      ],
    );
    final content = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_coverImage(palette, 240), _coverButtons()],
                ),
              ),
              const SizedBox(width: 32),
              Expanded(child: main),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _coverImage(palette, 112),
                  const SizedBox(width: 16),
                  Expanded(child: heading),
                ],
              ),
              _coverButtons(),
              const SizedBox(height: 8),
              main,
            ],
          );
    return PepeSubpage(
      title: loading || title.text.trim().isEmpty
          ? 'Карточка книги'
          : title.text.trim(),
      back: 'Книги',
      section: PepeSection.books,
      actions: [
        IconButton(
          tooltip: 'План чтения',
          icon: const Icon(Icons.event_note),
          onPressed: _openPlan,
        ),
        if (!wide)
          IconButton(
            tooltip: 'Статистика книги',
            onPressed: _openStatistics,
            icon: const Icon(Icons.bar_chart),
          ),
      ],
      children: loading
          ? const [
              Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ]
          : [AbsorbPointer(absorbing: saving, child: content)],
    );
  }
}
