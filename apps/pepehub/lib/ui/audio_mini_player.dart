import 'dart:io';

import 'package:flutter/material.dart';

import '../media/audio_controller.dart';
import '../media/audio_player_scope.dart';
import 'audio_page.dart';

/// Keeps playback available even on pages with their own bottom actions.
class AudioPlayerFooter extends StatelessWidget {
  final Widget? child;
  final bool enabled;
  const AudioPlayerFooter({super.key, this.child, this.enabled = true});
  @override
  Widget build(BuildContext context) {
    if (!enabled || child is AudioMiniPlayer) {
      return child ?? const SizedBox.shrink();
    }
    Widget player = AudioMiniPlayer(controller: AudioPlayerScope.of(context));
    if (child != null) {
      player = MediaQuery.removePadding(
        context: context,
        removeBottom: true,
        child: player,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [player, ?child],
    );
  }
}

/// Uses the existing playback controller; opening the screen never reloads audio.
class AudioMiniPlayer extends StatelessWidget {
  final AudioController? controller;
  final VoidCallback? onOpen;
  const AudioMiniPlayer({super.key, required this.controller, this.onOpen});
  @override
  Widget build(BuildContext context) {
    final audio = controller ?? AudioPlayerScope.of(context);
    if (audio == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        if (audio.current == null) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        return Material(
          color: colors.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value:
                      audio.bookFraction ??
                      (audio.duration.inMilliseconds > 0
                          ? (audio.position.inMilliseconds /
                                    audio.duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                          : 0),
                  minHeight: 2,
                ),
                ListTile(
                  key: const ValueKey('audio-mini-player'),
                  onTap:
                      onOpen ??
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AudioPage(controller: audio),
                        ),
                      ),
                  leading: SizedBox(
                    width: 42,
                    height: 52,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: audio.artwork == null
                          ? const Icon(Icons.headphones_rounded)
                          : Image.file(
                              File.fromUri(audio.artwork!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, error, stack) =>
                                  const Icon(Icons.headphones_rounded),
                            ),
                    ),
                  ),
                  title: Text(
                    audio.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    'Глава ${audio.trackIndex + 1} · ${audioTime(audio.position)} / ${audioTime(audio.duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton.filledTonal(
                    key: const ValueKey('mini-play-pause'),
                    tooltip: audio.playing ? 'Пауза' : 'Воспроизвести',
                    onPressed: audio.canPlay
                        ? (audio.playing ? audio.pause : audio.play)
                        : null,
                    icon: Icon(
                      audio.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
