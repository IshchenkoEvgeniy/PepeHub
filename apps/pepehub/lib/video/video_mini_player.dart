import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_session.dart';
import 'video_transcript_panel.dart';

class VideoMiniPlayer extends StatefulWidget {
  final VideoPlaybackSession session;
  final VoidCallback onOpen;
  const VideoMiniPlayer({
    super.key,
    required this.session,
    required this.onOpen,
  });
  @override
  State<VideoMiniPlayer> createState() => _VideoMiniPlayerState();
}

class _VideoMiniPlayerState extends State<VideoMiniPlayer> {
  Offset? position;
  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Не удалось выполнить действие: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      final session = widget.session, player = session.controller;
      if (player == null || !session.inMini || session.pageAttached) {
        return const SizedBox.shrink();
      }
      Widget picture() => Stack(
        fit: StackFit.expand,
        children: [
          player.audioOnly
              ? const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Icon(Icons.headphones, color: Colors.white),
                  ),
                )
              : player.engine.surface == null
              ? const ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Icon(Icons.ondemand_video, color: Colors.white),
                  ),
                )
              : Video(
                  controller: player.engine.surface!,
                  controls: NoVideoControls,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                ),
          if (!player.audioOnly && session.captions != null)
            VideoCaptionOverlay(
              captions: session.captions!,
              fontScale: .65,
              maxLines: 2,
              bottom: 6,
            ),
        ],
      );
      if (session.window.pip) {
        return Positioned.fill(
          child: ColoredBox(color: Colors.black, child: picture()),
        );
      }
      return LayoutBuilder(
        builder: (context, bounds) {
          final width = bounds.maxWidth < 600 ? 210.0 : 300.0;
          final actualWidth = width
              .clamp(1, (bounds.maxWidth - 24).clamp(1, double.infinity))
              .toDouble();
          final height =
              actualWidth / (player.engine.aspectRatio.clamp(.75, 2.35)) + 42;
          final padding = MediaQuery.paddingOf(context);
          final desired =
              position ??
              Offset(
                bounds.maxWidth - actualWidth - 16,
                bounds.maxHeight - height - padding.bottom - 84,
              );
          final offset = Offset(
            desired.dx.clamp(
              8,
              (bounds.maxWidth - actualWidth - 8).clamp(8, double.infinity),
            ),
            desired.dy.clamp(
              padding.top + 8,
              (bounds.maxHeight - height - padding.bottom - 8).clamp(
                padding.top + 8,
                double.infinity,
              ),
            ),
          );
          return Stack(
            children: [
              Positioned(
                left: offset.dx,
                top: offset.dy,
                width: actualWidth,
                height: height,
                child: Material(
                  key: const ValueKey('video-mini-player'),
                  elevation: 12,
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: widget.onOpen,
                          onPanUpdate: (event) =>
                              setState(() => position = offset + event.delta),
                          child: picture(),
                        ),
                      ),
                      SizedBox(
                        height: 42,
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Text(
                                  player.current?.title ?? 'Видео',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: player.state.playing
                                  ? 'Приостановить мини-плеер'
                                  : 'Продолжить мини-плеер',
                              onPressed: () => perform(player.toggle),
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: Icon(
                                player.state.playing
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.white,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 40,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Открыть видеоплеер',
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: widget.onOpen,
                              icon: const Icon(
                                Icons.open_in_full,
                                color: Colors.white,
                                size: 18,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 40,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Закрыть мини-плеер',
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => perform(session.close),
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 18,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 40,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
