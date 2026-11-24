import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/listening_timeline.dart';
import '../diagnostics/user_message.dart';
import '../media/audio_controller.dart';
import 'audio_page.dart' show audioTime;
import 'audio_rewind_options.dart';
import 'shelf_components.dart';

/// «История» of the current audiobook: days, what was heard and where the
/// listener jumped. A tap on heard audio continues from where it stopped;
/// a tap on a jump returns to where it started.
class AudioTimeline extends StatefulWidget {
  final AudioController controller;

  /// Called after a tap moved playback (the sheet closes itself).
  final VoidCallback? onMoved;
  const AudioTimeline({super.key, required this.controller, this.onMoved});

  /// Journal rows read for the list: about two weeks of daily listening.
  static const limit = 800;

  @override
  State<AudioTimeline> createState() => _AudioTimelineState();
}

enum _Filter { all, heard, jumps }

class _AudioTimelineState extends State<AudioTimeline> {
  AudioController get controller => widget.controller;
  Future<List<TimelineDay>>? days;
  String? book;
  _Filter filter = _Filter.all;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    controller.journal.changes.addListener(_journalChanged);
    _load();
  }

  @override
  void didUpdateWidget(AudioTimeline old) {
    super.didUpdateWidget(old);
    if (controller.current?.bookId != book) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    controller.journal.changes.removeListener(_journalChanged);
    super.dispose();
  }

  /// Listening is journaled every few seconds; refresh calmly.
  void _journalChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      if (mounted) _load();
    });
  }

  void _load() {
    final id = controller.current?.bookId;
    book = id;
    if (id == null) {
      setState(() => days = Future.value(const []));
      return;
    }
    final next = () async {
      await controller.flushJournal();
      final rows = await controller.journal.list(
        'audio_event',
        bookId: id,
        limit: AudioTimeline.limit,
      );
      return buildListeningTimeline([
        for (final row in rows)
          if (row.payload != null) row.payload!,
      ]);
    }();
    setState(() => days = next);
  }

  int? _trackIndex(String id) {
    final i = controller.tracks.indexWhere((t) => t.id == id);
    return i < 0 ? null : i;
  }

  /// «7. Глава седьмая» from the track, or the m4b chapter inside it.
  String _chapter(String trackId, int ms) {
    final i = _trackIndex(trackId);
    if (i == null) return 'Файл удалён';
    if (controller.current?.id == trackId && controller.chapters.isNotEmpty) {
      final inside = controller.chapters.lastWhere(
        (c) => c.startMs <= ms,
        orElse: () => controller.chapters.first,
      );
      return inside.title;
    }
    final name = controller.tracks[i].filename;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    return controller.tracks.length == 1 ? title : '${i + 1}. $title';
  }

  /// Share of the whole book, when every track length is known.
  String? _percent(String trackId, int ms) {
    final i = _trackIndex(trackId);
    if (i == null) return null;
    var before = 0, total = 0;
    for (var t = 0; t < controller.tracks.length; t++) {
      final d = controller.trackDuration(controller.tracks[t].id);
      if (d == null) return null;
      if (t < i) before += d.inMilliseconds;
      total += d.inMilliseconds;
    }
    if (total <= 0) return null;
    return '${((before + ms) * 100 / total).clamp(0, 100).floor()}%';
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _dayTitle(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    return '${day.day} ${months[day.month - 1]}'
        '${day.year == now.year ? '' : ' ${day.year}'}';
  }

  String _minutes(Duration d) {
    final m = d.inMinutes;
    if (m < 1) return '< 1 мин';
    if (m < 60) return '$m мин';
    return '${m ~/ 60} ч ${m % 60} мин';
  }

  String _signed(int ms) {
    final s = (ms.abs() / 1000).round();
    final text = s >= 60
        ? '${s ~/ 60} мин${s % 60 == 0 ? '' : ' ${s % 60} с'}'
        : '$s с';
    return '${ms < 0 ? '−' : '+'}$text';
  }

  Future<void> _go(String trackId, int ms, {required String reason}) async {
    if (_trackIndex(trackId) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Этого файла больше нет в книге')),
      );
      return;
    }
    widget.onMoved?.call();
    try {
      await controller.goToLocation(trackId, ms, reason: reason);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<_Filter>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: _Filter.all, label: Text('Всё')),
                    ButtonSegment(
                      value: _Filter.heard,
                      label: Text('Прослушано'),
                    ),
                    ButtonSegment(
                      value: _Filter.jumps,
                      label: Text('Переходы'),
                    ),
                  ],
                  selected: {filter},
                  onSelectionChanged: (value) =>
                      setState(() => filter = value.single),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<TimelineDay>>(
            future: days,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text(describeError(snapshot.error!)));
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = <Object>[];
              for (final day in data) {
                final entries = [
                  for (final e in day.entries)
                    if (filter == _Filter.all ||
                        filter == _Filter.heard && e is ListenSpan ||
                        filter == _Filter.jumps && e is JumpEntry)
                      e,
                ];
                if (entries.isEmpty) continue;
                rows
                  ..add(day.day)
                  ..addAll(entries);
              }
              if (rows.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      filter == _Filter.jumps
                          ? 'Переходов пока нет'
                          : 'История появится, когда вы начнёте слушать',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: palette.muted),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: rows.length,
                itemBuilder: (context, i) => switch (rows[i]) {
                  final DateTime day => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Text(
                      _dayTitle(day),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                    ),
                  ),
                  final ListenSpan span => _span(span, palette),
                  final JumpEntry jump => _jump(jump, palette),
                  _ => const SizedBox.shrink(),
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _span(ListenSpan span, ShelfPalette palette) {
    final percent = _percent(span.trackId, span.endMs);
    return ListTile(
      key: ValueKey('timeline-listen:${span.at.microsecondsSinceEpoch}'),
      dense: true,
      leading: Icon(Icons.headphones_outlined, color: palette.accent),
      title: Text(
        '${_chapter(span.trackId, span.startMs)} · '
        '${audioTime(Duration(milliseconds: span.startMs))} → '
        '${audioTime(Duration(milliseconds: span.endMs))}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          '${_clock(span.at)}–${_clock(span.end)}',
          _minutes(span.wall),
          ?percent,
          if (span.sleep) 'остановил таймер сна',
        ].join(' · '),
      ),
      trailing: IconButton(
        tooltip: 'Слушать с начала отрезка',
        icon: const Icon(Icons.first_page),
        onPressed: () => _go(span.trackId, span.startMs, reason: 'history'),
      ),
      // Where it stopped: the usual reason to look back.
      onTap: () => _go(span.trackId, span.endMs, reason: 'history'),
    );
  }

  Widget _jump(JumpEntry jump, ShelfPalette palette) {
    final delta = jump.deltaMs;
    final back = delta != null ? delta < 0 : jump.reason == 'rewind';
    final title = jump.skip
        ? '${back ? 'Назад' : 'Вперёд'}'
              '${jump.count > 1 ? ' ×${jump.count}' : ''}'
              '${delta == null ? '' : ' · ${_signed(delta)}'}'
        : audioSeekReasonLabel(jump.reason);
    final icon = switch (jump.reason) {
      'rewind' || 'forward' =>
        back ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      'chapter' => Icons.toc,
      'bookmark' => Icons.bookmark_outline,
      'book_timeline' => Icons.linear_scale,
      'history' => Icons.history,
      'note' => Icons.edit_note,
      'sleep_rewind' || 'resume_rewind' => Icons.replay,
      _ => Icons.swap_horiz,
    };
    final sameTrack = jump.fromTrack == jump.toTrack;
    final from =
        '${sameTrack ? '' : '${_chapter(jump.fromTrack, jump.fromMs)} '}'
        '${audioTime(Duration(milliseconds: jump.fromMs))}';
    final to =
        '${sameTrack ? '' : '${_chapter(jump.toTrack, jump.toMs)} '}'
        '${audioTime(Duration(milliseconds: jump.toMs))}';
    return ListTile(
      key: ValueKey('timeline-jump:${jump.at.microsecondsSinceEpoch}'),
      dense: true,
      visualDensity: jump.skip ? VisualDensity.compact : null,
      leading: Icon(icon, color: palette.muted, size: jump.skip ? 20 : 24),
      title: Text(
        sameTrack ? '$title · ${_chapter(jump.toTrack, jump.toMs)}' : title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_clock(jump.at)} · $from → $to',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Перейти туда, куда перематывали',
        icon: const Icon(Icons.redo),
        onPressed: () => _go(jump.toTrack, jump.toMs, reason: 'history'),
      ),
      // Back to where the jump started: the place you were listening to.
      onTap: () => _go(jump.fromTrack, jump.fromMs, reason: 'history'),
    );
  }
}
