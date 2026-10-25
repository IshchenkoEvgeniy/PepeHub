import 'package:flutter/material.dart';

import '../video/models.dart';
import '../video/video_repository.dart';
import '../ui/pepe_widgets.dart';
import '../ui/audio_mini_player.dart';

class MusicStatisticsPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem? item;
  const MusicStatisticsPage({super.key, required this.repository, this.item});
  @override
  State<MusicStatisticsPage> createState() => _MusicStatisticsPageState();
}

class _MusicStatisticsPageState extends State<MusicStatisticsPage> {
  int days = 30;
  Map<String, int> daily = {}, tracks = {};
  Map<String, String> titles = {};
  int totalMs = 0;
  String? error;
  bool loading = true;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() => loading = true);
    try {
      final songs = (await widget.repository.lessons(itemId: widget.item?.id))
          .where((song) => song.isAudio)
          .toList();
      final since = days == 0
          ? null
          : DateTime.now().subtract(Duration(days: days));
      final intervals = await widget.repository.intervals(
        music: true,
        lessonIds: widget.item == null
            ? null
            : songs.map((song) => song.id).toSet(),
        start: since,
      );
      final nextDays = <String, int>{}, nextTracks = <String, int>{};
      var total = 0;
      for (final interval in intervals) {
        final from = since == null || interval.startedAt.isAfter(since)
            ? interval.startedAt
            : since;
        final wall = interval.endedAt
            .difference(from)
            .inMilliseconds
            .clamp(0, interval.wallMs);
        if (wall <= 0) continue;
        final day = interval.localDay;
        nextDays[day] = (nextDays[day] ?? 0) + wall;
        nextTracks[interval.lessonId] =
            (nextTracks[interval.lessonId] ?? 0) + wall;
        total += wall;
      }
      if (!mounted || request != _request) return;
      setState(() {
        daily = nextDays;
        tracks = nextTracks;
        totalMs = total;
        titles = {for (final song in songs) song.id: song.title};
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          error = 'Не удалось загрузить музыку: $e';
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ordered = tracks.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final calendar = daily.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return Scaffold(
      appBar: AppBar(title: const Text('Статистика музыки')),
      bottomNavigationBar: const AudioPlayerFooter(),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Только музыкальные треки. Время видеокурсов и аудиокниг сюда не входит.',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final period in [7, 30, 365, 0])
                ChoiceChip(
                  label: Text(period == 0 ? 'Всё время' : '$period дней'),
                  selected: days == period,
                  onSelected: (_) {
                    days = period;
                    _load();
                  },
                ),
            ],
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          ListTile(
            title: const Text('Время прослушивания'),
            trailing: Text(pepeTime(totalMs)),
          ),
          ListTile(
            title: const Text('Дней с музыкой'),
            trailing: Text('${daily.length}'),
          ),
          ListTile(
            title: const Text('Разных треков'),
            trailing: Text('${tracks.length}'),
          ),
          const Text('Чаще слушаете'),
          for (final entry in ordered.take(30))
            ListTile(
              title: Text(titles[entry.key] ?? 'Удалённый трек'),
              trailing: Text(pepeTime(entry.value)),
            ),
          const Text('По дням'),
          for (final entry in calendar)
            ListTile(
              title: Text(entry.key),
              trailing: Text(pepeTime(entry.value)),
            ),
          if (!loading && totalMs == 0)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('За этот период прослушиваний пока нет.'),
            ),
        ],
      ),
    );
  }
}
