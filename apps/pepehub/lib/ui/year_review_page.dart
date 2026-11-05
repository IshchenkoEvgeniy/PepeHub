import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../statistics/annual_summary.dart';
import '../library/reading_insights.dart';
import '../video/video_frame_export.dart';
import 'pepe_widgets.dart';

class AnnualCategoryPanel extends StatelessWidget {
  final String title, field;
  final List<YearBook> books;
  const AnnualCategoryPanel({
    super.key,
    required this.title,
    required this.field,
    required this.books,
  });
  @override
  Widget build(BuildContext context) {
    final categories = annualCategories(books, field);
    Widget row(AnnualCategory c) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(c.label, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text('${c.books} произв. · ${c.completions} заверш.'),
    );
    return PepePanel(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (categories.isEmpty)
            const Text('За этот год завершённых произведений нет.'),
          for (final c in categories.take(5)) row(c),
          if (categories.length > 5)
            TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => SizedBox(
                  height: MediaQuery.sizeOf(context).height * .8,
                  child: Column(
                    children: [
                      ListTile(
                        title: Text('$title · ${categories.length}'),
                        trailing: IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: categories.length,
                          itemBuilder: (_, i) => row(categories[i]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              child: Text('Все ${categories.length}'),
            ),
          if (field != 'series')
            const Text(
              'Произведение с несколькими значениями входит в каждую группу. Сумма групп может превышать число произведений.',
            ),
        ],
      ),
    );
  }
}

List<String> _reviewLines(AnnualSummary data, DateTime now) {
  final longest = data.longestDay;
  final genre = data.favoriteGenre;
  return [
    'PEPEHUB · ${data.year}',
    switch (data.scope) {
      'reading' => 'Мой год с книгами',
      'audio' => 'Мой год с аудиокнигами',
      _ => 'Мой год с книгами и аудио',
    },
    'Завершений: ${data.completions} · Уникальных произведений: ${data.books.length}',
    '${bookActivityTime(data.milliseconds)} · Дней с книгой: ${data.activeDays}',
    '',
    'РЕКОРДЫ',
    'Самый длинный день: ${longest == null ? 'нет данных' : '${bookDateLabel(longest.key)} · ${bookActivityTime(longest.value)}'}',
    'Лучшая серия года: ${data.bestStreak(now)} дн. · от 5 минут в день',
    'Любимый жанр: ${genre == null ? 'не указан' : '${genre.label} · произведений: ${genre.books}'}',
    '',
    'ЛУЧШИЕ КНИГИ · ПО МОИМ ОЦЕНКАМ',
    if (data.bestBooks.isEmpty) 'Оценки ещё не указаны',
    for (final b in data.bestBooks.take(5))
      'Оценка ${bookAmount(b.rating!)} · ${b.entry.item.title}',
    '',
    'БОЛЬШЕ ВСЕГО ВРЕМЕНИ',
    if (data.bookTimes.values.every((v) => v <= 0)) 'Нет записей времени',
    ...((data.bookTimes.entries.where((e) => e.value > 0).toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(5)
        .map(
          (e) =>
              '${bookActivityTime(e.value)} · ${data.titles[e.key] ?? 'Произведение без названия'}',
        )),
    '',
    'Время может включать подписанные в статистике оценки. Рекорды дней учитывают только записи занятий.',
  ];
}

Future<Uint8List> renderAnnualSummaryPng(
  AnnualSummary data,
  DateTime now,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final lines = _reviewLines(data, now);
  var y = 64.0;
  final painters = <(TextPainter, double)>[];
  for (var i = 0; i < lines.length; i++) {
    final heading =
        i == 0 || (lines[i].isNotEmpty && lines[i] == lines[i].toUpperCase());
    final painter = TextPainter(
      maxLines: 3,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: lines[i],
        style: TextStyle(
          fontFamily: 'Onest',
          fontSize: i == 0
              ? 60
              : heading
              ? 30
              : 28,
          height: 1.35,
          fontWeight: heading ? FontWeight.w700 : FontWeight.w400,
          color: heading ? const Color(0xffe8bd78) : const Color(0xfff4eee6),
        ),
      ),
    )..layout(maxWidth: 952);
    painters.add((painter, y));
    y += painter.height + (lines[i].isEmpty ? 18 : 16);
  }
  canvas.drawRect(
    Rect.fromLTWH(0, 0, 1080, y + 64),
    Paint()..color = const Color(0xff182420),
  );
  for (final (painter, top) in painters) {
    painter.paint(canvas, Offset(64, top));
    painter.dispose();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1080, (y + 64).ceil());
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Не удалось создать PNG');
    return bytes.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class YearReviewPage extends StatefulWidget {
  final AnnualSummary summary;
  const YearReviewPage({super.key, required this.summary});
  @override
  State<YearReviewPage> createState() => _YearReviewPageState();
}

class _YearReviewPageState extends State<YearReviewPage> {
  bool exporting = false;
  String? error;
  Future<void> _export() async {
    setState(() {
      exporting = true;
      error = null;
    });
    try {
      final bytes = await renderAnnualSummaryPng(
        widget.summary,
        DateTime.now(),
      );
      final path = await saveVideoFrame(
        bytes,
        'PepeHub-${widget.summary.year}-${widget.summary.scope}.png',
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Итоги года сохранены в PNG')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось сохранить итоги: $e');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.summary;
    return PepeSubpage(
      title: 'Итоги ${data.year}',
      actions: [
        IconButton(
          key: const ValueKey('year-review-export'),
          tooltip: 'Сохранить картинкой · PNG',
          onPressed: exporting ? null : _export,
          icon: const Icon(Icons.image_outlined),
        ),
      ],
      children: [
        if (exporting) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        for (final line in _reviewLines(data, DateTime.now()))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              line,
              style: line == line.toUpperCase()
                  ? Theme.of(context).textTheme.titleLarge
                  : Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        AnnualCategoryPanel(title: 'Жанры', field: 'genre', books: data.books),
        AnnualCategoryPanel(
          title: 'Авторы',
          field: 'author',
          books: data.books,
        ),
        AnnualCategoryPanel(title: 'Серии', field: 'series', books: data.books),
      ],
    );
  }
}
