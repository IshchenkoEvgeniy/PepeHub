import 'dart:async';

import 'package:audio_service/audio_service.dart';

/// One Android media session follows the current owner of the app's sound.
/// UI book controls still address AudioController directly.
class SharedMediaHandler extends BaseAudioHandler {
  final AudioHandler books;
  late AudioHandler owner;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _generation = 0;
  SharedMediaHandler(this.books) {
    setOwner(books);
  }
  void setOwner(AudioHandler next) {
    if (_subscriptions.isNotEmpty && identical(owner, next)) return;
    final generation = ++_generation;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    owner = next;
    _subscriptions.add(
      next.playbackState.listen((value) {
        if (generation == _generation) playbackState.add(value);
      }),
    );
    _subscriptions.add(
      next.mediaItem.listen((value) {
        if (generation == _generation) mediaItem.add(value);
      }),
    );
    _subscriptions.add(
      next.queue.listen((value) {
        if (generation == _generation) queue.add(value);
      }),
    );
  }

  void release(AudioHandler previous) {
    if (identical(owner, previous)) setOwner(books);
  }

  @override
  Future<void> play() => owner.play();
  @override
  Future<void> pause() => owner.pause();
  @override
  Future<void> stop() => owner.stop();
  @override
  Future<void> seek(Duration position) => owner.seek(position);
  @override
  Future<void> rewind() => owner.rewind();
  @override
  Future<void> fastForward() => owner.fastForward();
  @override
  Future<void> skipToNext() => owner.skipToNext();
  @override
  Future<void> skipToPrevious() => owner.skipToPrevious();
  @override
  Future<void> skipToQueueItem(int index) => owner.skipToQueueItem(index);
  @override
  Future<void> setSpeed(double speed) => owner.setSpeed(speed);
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      owner.setShuffleMode(shuffleMode);
  @override
  Future<void> onTaskRemoved() => owner.onTaskRemoved();
  Future<void> close() async {
    ++_generation;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
