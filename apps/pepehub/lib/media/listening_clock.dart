/// Counts monotonic wall time only while sound is playing. Seeking and playback speed
/// do not affect this duration. Buffering and pauses explicitly stop accumulation.
class ListeningClock {
  final int Function() nowMilliseconds;
  int _total = 0;
  int? _since;
  ListeningClock(this.nowMilliseconds);
  void setAudible(bool audible) {
    if (audible) {
      _since ??= nowMilliseconds();
    } else if (_since != null) {
      _total += (nowMilliseconds() - _since!).clamp(0, 1 << 53);
      _since = null;
    }
  }

  int get milliseconds =>
      _total +
      (_since == null ? 0 : (nowMilliseconds() - _since!).clamp(0, 1 << 53));
}
