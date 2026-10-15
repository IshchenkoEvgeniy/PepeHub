import 'package:flutter/material.dart';

import 'video_controller.dart';
import 'video_tools.dart';

/// Only the transport is persistent. Tools and study content open on demand.
class VideoCompactControls extends StatelessWidget {
  final VideoPlaybackController player;
  final bool enabled, fullscreen, visible, locked, miniWindow;
  final double? scrub;
  final Widget? seekPreview;
  final VoidCallback onBack,
      onMore,
      onStudy,
      onCaptions,
      onNote,
      onFullscreen,
      onLock;
  final void Function(double) onScrub;
  final void Function(double) onSeek;
  final VoidCallback onScrubStart;
  final Future<void> Function(Future<void> Function()) perform;
  const VideoCompactControls({
    super.key,
    required this.player,
    required this.enabled,
    required this.fullscreen,
    required this.visible,
    required this.locked,
    required this.miniWindow,
    required this.scrub,
    this.seekPreview,
    required this.onBack,
    required this.onMore,
    required this.onStudy,
    required this.onCaptions,
    required this.onNote,
    required this.onFullscreen,
    required this.onLock,
    required this.onScrub,
    required this.onSeek,
    required this.onScrubStart,
    required this.perform,
  });
  @override
  Widget build(BuildContext context) {
    if (locked) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SafeArea(
            child: IconButton.filledTonal(
              tooltip: 'Разблокировать управление',
              onPressed: onLock,
              icon: const Icon(Icons.lock_open),
            ),
          ),
        ),
      );
    }
    if (!visible) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth >= 600;
        Widget button(
          String tooltip,
          IconData icon,
          VoidCallback? tap, {
          double size = 26,
        }) => IconButton(
          tooltip: tooltip,
          onPressed: tap,
          icon: Icon(icon, size: size),
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.all(8),
          ),
        );
        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 18),
                    child: Row(
                      children: [
                        button(
                          fullscreen
                              ? 'Выйти из полного экрана'
                              : 'Закрыть плеер',
                          Icons.arrow_back,
                          onBack,
                        ),
                        Expanded(
                          child: Text(
                            player.current?.title ?? 'Видео',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (!miniWindow) ...[
                          button(
                            'Быстрая заметка',
                            Icons.edit_note,
                            enabled ? onNote : null,
                          ),
                          button(
                            'Дорожки и субтитры',
                            Icons.closed_caption_outlined,
                            enabled ? onCaptions : null,
                          ),
                          button(
                            'Уроки, расшифровка и заметки',
                            Icons.playlist_play,
                            enabled ? onStudy : null,
                          ),
                        ],
                        button('Инструменты плеера', Icons.more_vert, onMore),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 24 : 10,
                      18,
                      wide ? 24 : 10,
                      8,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (scrub != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ?seekPreview,
                                Text(
                                  videoTimestamp(scrub!.round(), precise: true),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          children: [
                            Text(
                              videoTimestamp(
                                (scrub ?? player.positionMs).round(),
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Expanded(
                              child: SizedBox(
                                height: 30,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 3,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14,
                                    ),
                                  ),
                                  child: Slider(
                                    key: const ValueKey('video-position'),
                                    value:
                                        (scrub ?? player.positionMs.toDouble())
                                            .clamp(
                                              0,
                                              player.state.durationMs > 0
                                                  ? player.state.durationMs
                                                        .toDouble()
                                                  : 1,
                                            ),
                                    max: player.state.durationMs > 0
                                        ? player.state.durationMs.toDouble()
                                        : 1,
                                    onChangeStart:
                                        enabled && player.state.durationMs > 0
                                        ? (_) => onScrubStart()
                                        : null,
                                    onChanged:
                                        enabled && player.state.durationMs > 0
                                        ? onScrub
                                        : null,
                                    onChangeEnd:
                                        enabled && player.state.durationMs > 0
                                        ? onSeek
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                            Text(
                              player.state.durationMs > 0
                                  ? videoTimestamp(player.state.durationMs)
                                  : '—',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            if (wide)
                              button(
                                'Заблокировать управление',
                                Icons.lock_outline,
                                onLock,
                              ),
                            if (bounds.maxWidth >= 420 && !miniWindow)
                              button(
                                'Предыдущий урок',
                                Icons.skip_previous,
                                enabled && player.index > 0
                                    ? () => perform(player.previous)
                                    : null,
                              ),
                            button(
                              'Назад на 10 секунд',
                              Icons.replay_10,
                              enabled
                                  ? () => perform(() => player.skip(-10000))
                                  : null,
                            ),
                            IconButton.filled(
                              key: const ValueKey('video-play-pause'),
                              tooltip: player.state.playing
                                  ? 'Пауза'
                                  : 'Смотреть',
                              onPressed: enabled
                                  ? () => perform(player.toggle)
                                  : null,
                              icon: Icon(
                                player.state.playing
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                size: 30,
                              ),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(54, 54),
                                padding: const EdgeInsets.all(10),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                              ),
                            ),
                            button(
                              'Вперёд на 10 секунд',
                              Icons.forward_10,
                              enabled
                                  ? () => perform(() => player.skip(10000))
                                  : null,
                            ),
                            if (bounds.maxWidth >= 420 && !miniWindow)
                              button(
                                'Следующий урок',
                                Icons.skip_next,
                                enabled &&
                                        player.index + 1 < player.lessons.length
                                    ? () => perform(player.next)
                                    : null,
                              ),
                            PopupMenuButton<double>(
                              tooltip: 'Скорость воспроизведения',
                              enabled: enabled,
                              onSelected: (speed) =>
                                  perform(() => player.setSpeed(speed)),
                              itemBuilder: (_) => [
                                for (final speed in [
                                  .5,
                                  .75,
                                  1.0,
                                  1.25,
                                  1.5,
                                  1.75,
                                  2.0,
                                  2.5,
                                  3.0,
                                ])
                                  CheckedPopupMenuItem(
                                    value: speed,
                                    checked: player.state.speed == speed,
                                    child: Text('$speed×'),
                                  ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 12,
                                ),
                                child: Text(
                                  '${player.state.speed}×',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                            button(
                              fullscreen
                                  ? 'Выйти из полного экрана'
                                  : 'Полный экран',
                              fullscreen
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                              onFullscreen,
                            ),
                          ],
                        ),
                        if (player.loopRunning)
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${player.loopWaiting ? 'Произнесите фразу' : 'A–B'} · ${player.loopCompletedPasses}/${player.loop?.totalPasses ?? '∞'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              TextButton(
                                onPressed: () => perform(player.stopLoop),
                                child: const Text('Остановить'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
