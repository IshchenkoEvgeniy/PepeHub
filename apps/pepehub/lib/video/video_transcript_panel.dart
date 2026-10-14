import 'package:flutter/material.dart';

import 'video_captions_controller.dart';
import 'video_subtitles.dart';
import 'video_tools.dart';

class VideoTranscriptPanel extends StatefulWidget {
  final VideoCaptionsController captions;
  final Future<void> Function(VideoSubtitleRecord, VideoSubtitleCue) onSeek,
      onRepeat,
      onNote;
  const VideoTranscriptPanel({
    super.key,
    required this.captions,
    required this.onSeek,
    required this.onRepeat,
    required this.onNote,
  });
  @override
  State<VideoTranscriptPanel> createState() => _VideoTranscriptPanelState();
}

class _VideoTranscriptPanelState extends State<VideoTranscriptPanel> {
  String? selected;
  String query = '', _lastQuery = '';
  int page = 0;
  VideoSubtitleDocument? _lastDocument;
  List<int> filtered = [];
  @override
  void initState() {
    super.initState();
    widget.captions.addListener(_changed);
  }

  @override
  void didUpdateWidget(VideoTranscriptPanel previous) {
    super.didUpdateWidget(previous);
    if (previous.captions != widget.captions) {
      previous.captions.removeListener(_changed);
      widget.captions.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.captions.removeListener(_changed);
    super.dispose();
  }

  Future<void> _fullText(VideoSubtitleCue cue) => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(videoTimestamp(cue.startMs, precise: true)),
      content: SingleChildScrollView(child: SelectableText(cue.text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final model = widget.captions;
    final sources = model.records
        .where((record) => model.documents[record.id]?.cues.isNotEmpty == true)
        .toList();
    if (sources.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Добавьте SRT/WebVTT в настройках субтитров для поиска и повторения реплик. Встроенный текст и ASS пока не извлекаются в полную расшифровку.',
        ),
      );
    }
    final source = sources.firstWhere(
      (source) => source.id == selected,
      orElse: () => sources.firstWhere(
        (source) => source.id == model.primaryId,
        orElse: () => sources.first,
      ),
    );
    final document = model.documents[source.id]!,
        time = model.playback.positionMs - model.delayFor(source.id);
    if (_lastDocument != document || _lastQuery != query) {
      _lastDocument = document;
      _lastQuery = query;
      final search = query.toLowerCase().trim();
      filtered = [
        for (var i = 0; i < document.cues.length; i++)
          if (search.isEmpty ||
              document.cues[i].text.toLowerCase().contains(search))
            i,
      ];
      page = 0;
    }
    final pages = ((filtered.length + 99) ~/ 100).clamp(1, 100000),
        current = document.activeAt(time).lastOrNull;
    page = page.clamp(0, pages - 1);
    final visible = filtered.skip(page * 100).take(100);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('video-transcript-source:${source.id}'),
          initialValue: source.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Текст для изучения'),
          items: [
            for (final source in sources)
              DropdownMenuItem(
                value: source.id,
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            selected = value;
            page = 0;
          }),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('video-transcript-search'),
          decoration: const InputDecoration(
            labelText: 'Поиск по репликам',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => query = value),
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${filtered.length} реплик · страница ${page + 1} из $pages'),
            TextButton(
              onPressed: current == null
                  ? null
                  : () {
                      final index = filtered.indexWhere(
                        (index) => document.cues[index].id == current.id,
                      );
                      if (index >= 0) setState(() => page = index ~/ 100);
                    },
              child: const Text('Текущая фраза'),
            ),
            IconButton(
              tooltip: 'Предыдущая фраза',
              onPressed:
                  document.nextIndex(time) - (current == null ? 1 : 2) < 0
                  ? null
                  : () => widget.onSeek(
                      source,
                      document.cues[document.nextIndex(time) -
                          (current == null ? 1 : 2)],
                    ),
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              tooltip: 'Следующая фраза',
              onPressed: document.nextIndex(time) >= document.cues.length
                  ? null
                  : () => widget.onSeek(
                      source,
                      document.cues[document.nextIndex(time)],
                    ),
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              tooltip: 'Предыдущая страница реплик',
              onPressed: page == 0 ? null : () => setState(() => page--),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Следующая страница реплик',
              onPressed: page + 1 >= pages
                  ? null
                  : () => setState(() => page++),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Ничего не найдено'),
          ),
        for (final index in visible)
          ListTile(
            key: ValueKey('video-cue:${source.id}:${document.cues[index].id}'),
            selected:
                document.cues[index].startMs <= time &&
                document.cues[index].endMs > time,
            selectedTileColor: Theme.of(context).colorScheme.primaryContainer
                .withValues(alpha: .25),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              document.cues[index].text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${videoTimestamp((document.cues[index].startMs + model.delayFor(source.id)).clamp(0, 1 << 53), precise: true)} — ${videoTimestamp((document.cues[index].endMs + model.delayFor(source.id)).clamp(0, 1 << 53), precise: true)}',
            ),
            onTap: model.busy
                ? null
                : () => widget.onSeek(source, document.cues[index]),
            trailing: PopupMenuButton<String>(
              tooltip: 'Действия с репликой',
              onSelected: (action) async {
                switch (action) {
                  case 'repeat':
                    await widget.onRepeat(source, document.cues[index]);
                  case 'note':
                    await widget.onNote(source, document.cues[index]);
                  case 'text':
                    await _fullText(document.cues[index]);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'repeat', child: Text('Повторить фразу')),
                PopupMenuItem(value: 'note', child: Text('Заметка с цитатой')),
                PopupMenuItem(value: 'text', child: Text('Полный текст')),
              ],
            ),
          ),
      ],
    );
  }
}

class VideoCaptionOverlay extends StatelessWidget {
  final VideoCaptionsController captions;
  final double bottom, fontScale;
  final int maxLines;
  const VideoCaptionOverlay({
    super.key,
    required this.captions,
    this.bottom = 12,
    this.fontScale = 1,
    this.maxLines = 4,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: captions,
    builder: (context, _) {
      final original = captions.primaryText,
          translation = captions.translationText;
      final nativePrimary =
          captions.playback.engine.rendersNativeSubtitles &&
          captions.settings.subtitle != 'no' &&
          (captions.primaryId == null ||
              captions.record(captions.primaryId!)?.format ==
                  VideoSubtitleFormat.ass);
      if (original.isEmpty && translation.isEmpty) {
        return const SizedBox.shrink();
      }
      return IgnorePointer(
        child: LayoutBuilder(
          builder: (context, bounds) => Align(
            // A native subtitle renderer owns its lower area; put an external
            // translation above the image rather than on top of that caption.
            alignment: nativePrimary
                ? Alignment.topCenter
                : Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                nativePrimary ? (bottom > 12 ? 64 : 12) : 8,
                12,
                (nativePrimary ? 12.0 : bottom).clamp(
                  0,
                  (bounds.maxHeight - 12).clamp(0, 1 << 30).toDouble(),
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      (bounds.maxHeight -
                              (nativePrimary
                                  ? (bottom > 12 ? 64 : 12)
                                  : bottom) -
                              12)
                          .clamp(0, 1 << 30)
                          .toDouble(),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (text, color, captionKey) in [
                      (original, Colors.white, 'video-caption-original'),
                      (
                        translation,
                        const Color(0xffffdc8a),
                        'video-caption-translation',
                      ),
                    ])
                      if (text.isNotEmpty)
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            color: captions.settings.subtitleBackground
                                ? Colors.black.withValues(alpha: .7)
                                : null,
                            child: Text(
                              text,
                              key: ValueKey(captionKey),
                              textAlign: TextAlign.center,
                              maxLines: maxLines,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize:
                                    captions.settings.fontSize * fontScale,
                                height: 1.2,
                                color: color,
                                shadows: const [
                                  Shadow(blurRadius: 3, color: Colors.black),
                                ],
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
