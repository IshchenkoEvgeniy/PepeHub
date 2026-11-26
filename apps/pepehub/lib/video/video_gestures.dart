import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'video_tools.dart';

/// Touch gestures over the video, the way phone players work:
/// double tap on the left or right third seeks ∓10 s (taps right after add
/// more), in the middle toggles fullscreen; holding plays at 2×; a sideways
/// swipe scrubs; a vertical swipe changes volume (right half) or window
/// brightness (left half). A mouse keeps double click = fullscreen.
///
/// Swipes come from the [InteractiveViewer] callbacks, so pinch zoom keeps
/// working; while the video is zoomed one finger pans it instead.
class VideoGestureLayer extends StatefulWidget {
  final Widget viewport;
  final List<Widget> overlays;
  final TransformationController zoom;
  final bool enabled, locked;

  /// The controls react to taps even while seeking is impossible.
  final VoidCallback onTap, onFullscreen;
  final void Function(int milliseconds) onSkip;

  /// Returns false when holding cannot speed up (for example, paused).
  final bool Function(bool holding) onHold;
  final int Function() position, duration;
  final VoidCallback onScrubStart;
  final void Function(double positionMs) onScrub, onSeek;
  final VoidCallback onScrubCancel;
  final double Function() volume;
  final void Function(double volume) onVolume;

  /// Null where the window brightness cannot change (desktop).
  final Future<double?> Function()? brightness;
  final void Function(double brightness)? onBrightness;

  /// Pinch or pan of the zoomed video: the page hides the controls.
  final VoidCallback onZoomStart, onZoomEnd;

  const VideoGestureLayer({
    super.key,
    required this.viewport,
    this.overlays = const [],
    required this.zoom,
    required this.enabled,
    required this.locked,
    required this.onTap,
    required this.onFullscreen,
    required this.onSkip,
    required this.onHold,
    required this.position,
    required this.duration,
    required this.onScrubStart,
    required this.onScrub,
    required this.onSeek,
    required this.onScrubCancel,
    required this.volume,
    required this.onVolume,
    this.brightness,
    this.onBrightness,
    required this.onZoomStart,
    required this.onZoomEnd,
  });

  @override
  State<VideoGestureLayer> createState() => VideoGestureLayerState();
}

enum _Swipe { scrub, volume, brightness }

class VideoGestureLayerState extends State<VideoGestureLayer> {
  static const seekStep = 10000;

  /// One full-width swipe scrubs two minutes.
  static const scrubSpanMs = 120000;
  static const _slop = 14.0;

  Size _size = Size.zero;
  bool _zoomed = false;

  // Double-tap seeking.
  TapDownDetails? _doubleTap;
  int _seekSide = 0, _seekTotal = 0;
  Timer? _seekTimer;

  // Hold for 2×.
  bool _holding = false;
  PointerDeviceKind? _pressKind;

  // Swipes.
  Offset? _swipeStart, _down;
  _Swipe? _swipe;
  bool _swipeAllowed = false, _pinching = false;
  double _swipeBase = 0, _swipeValue = 0;
  double? _brightness;
  Timer? _levelTimer;
  bool _showLevel = false;
  _Swipe _levelKind = _Swipe.volume;

  @override
  void initState() {
    super.initState();
    widget.zoom.addListener(_zoomChanged);
  }

  @override
  void didUpdateWidget(VideoGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoom != widget.zoom) {
      oldWidget.zoom.removeListener(_zoomChanged);
      widget.zoom.addListener(_zoomChanged);
    }
    if (!widget.enabled || widget.locked) _endHold();
  }

  @override
  void dispose() {
    widget.zoom.removeListener(_zoomChanged);
    _seekTimer?.cancel();
    _levelTimer?.cancel();
    if (_holding) widget.onHold(false);
    super.dispose();
  }

  void _zoomChanged() {
    final zoomed = widget.zoom.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  bool get _seeking => _seekTimer?.isActive == true;

  int _sideOf(Offset position) {
    final width = _size.width;
    if (width <= 0) return 0;
    if (position.dx < width * .35) return -1;
    if (position.dx > width * .65) return 1;
    return 0;
  }

  void _seekBy(int side) {
    widget.onSkip(side * seekStep);
    _seekTimer?.cancel();
    setState(() {
      if (_seekSide != side) _seekTotal = 0;
      _seekSide = side;
      _seekTotal += seekStep;
    });
    _seekTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _seekTotal = 0);
    });
  }

  void _handleTap(TapUpDetails details) {
    if (widget.locked) return;
    // Taps right after a double-tap seek keep seeking on the same side.
    final side = _sideOf(details.localPosition);
    if (_seeking && widget.enabled && side != 0 && side == _seekSide) {
      _seekBy(side);
      return;
    }
    widget.onTap();
  }

  void _handleDoubleTap() {
    final details = _doubleTap;
    if (widget.locked || details == null) return;
    final side = details.kind == PointerDeviceKind.mouse
        ? 0
        : _sideOf(details.localPosition);
    if (side == 0 || !widget.enabled) {
      widget.onFullscreen();
    } else {
      _seekBy(side);
    }
  }

  void _startHold(LongPressStartDetails details) {
    if (widget.locked ||
        !widget.enabled ||
        _pressKind == PointerDeviceKind.mouse ||
        _holding) {
      return;
    }
    if (widget.onHold(true)) setState(() => _holding = true);
  }

  void _endHold() {
    if (!_holding) return;
    _holding = false;
    widget.onHold(false);
    if (mounted) setState(() {});
  }

  void _interactionStart(ScaleStartDetails details) {
    final touch =
        details.kind == PointerDeviceKind.touch ||
        details.kind == PointerDeviceKind.stylus;
    _swipeAllowed =
        touch &&
        widget.enabled &&
        !widget.locked &&
        !_zoomed &&
        !_holding &&
        details.pointerCount == 1;
    _pinching = !_swipeAllowed;
    // Measure from where the finger landed, not where the swipe was
    // recognised, so the first few pixels count too.
    _swipeStart = _swipeAllowed && _down != null
        ? _down
        : details.localFocalPoint;
    _swipe = null;
    if (_pinching) widget.onZoomStart();
    if (_swipeAllowed && widget.brightness != null) {
      // Read ahead: a left-side swipe starts from the current level.
      unawaited(
        widget.brightness!()
            .then((value) => _brightness = value)
            .catchError((Object _) => null),
      );
    }
  }

  void _interactionUpdate(ScaleUpdateDetails details) {
    if (_pinching) return;
    if (details.pointerCount > 1 || !widget.enabled || widget.locked) {
      // A second finger turns the swipe into pinch zoom.
      _cancelSwipe();
      _pinching = true;
      widget.onZoomStart();
      return;
    }
    if (!_swipeAllowed || _swipeStart == null) return;
    final moved = details.localFocalPoint - _swipeStart!;
    if (_swipe == null) {
      if (moved.distance < _slop) return;
      if (moved.dx.abs() > moved.dy.abs()) {
        if (widget.duration() <= 0) {
          _swipeAllowed = false;
          return;
        }
        _swipe = _Swipe.scrub;
        _swipeBase = widget.position().toDouble();
        widget.onScrubStart();
      } else if (_swipeStart!.dx < _size.width / 2 &&
          widget.onBrightness != null) {
        _swipe = _Swipe.brightness;
        _levelKind = _Swipe.brightness;
        _swipeBase = _brightness ?? .5;
      } else {
        _swipe = _Swipe.volume;
        _levelKind = _Swipe.volume;
        _swipeBase = widget.volume().clamp(0, 100) / 100;
      }
      _levelTimer?.cancel();
    }
    switch (_swipe!) {
      case _Swipe.scrub:
        final width = math.max(_size.width, 1.0);
        final duration = widget.duration().toDouble();
        _swipeValue = (_swipeBase + moved.dx / width * scrubSpanMs).clamp(
          0,
          duration,
        );
        widget.onScrub(_swipeValue);
      case _Swipe.volume || _Swipe.brightness:
        final height = math.max(_size.height * .7, 1.0);
        _swipeValue = (_swipeBase - moved.dy / height).clamp(0, 1);
        if (_swipe == _Swipe.volume) {
          widget.onVolume(_swipeValue * 100);
        } else {
          _brightness = _swipeValue;
          widget.onBrightness!(_swipeValue);
        }
        _showLevel = true;
    }
    setState(() {});
  }

  void _interactionEnd(ScaleEndDetails details) {
    if (_pinching) {
      _pinching = false;
      widget.onZoomEnd();
    }
    if (_swipe == _Swipe.scrub) widget.onSeek(_swipeValue);
    if (_swipe == _Swipe.volume || _swipe == _Swipe.brightness) {
      _levelTimer?.cancel();
      _levelTimer = Timer(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showLevel = false);
      });
    }
    _swipe = null;
    _swipeStart = null;
    setState(() {});
  }

  void _cancelSwipe() {
    if (_swipe == _Swipe.scrub) widget.onScrubCancel();
    _swipe = null;
    _swipeAllowed = false;
  }

  Widget _bubble(Widget child) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        child: IconTheme.merge(
          data: const IconThemeData(color: Colors.white),
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      _size = bounds.biggest;
      final scrubbing = _swipe == _Swipe.scrub;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _handleTap,
        onDoubleTapDown: (details) => _doubleTap = details,
        onDoubleTap: _handleDoubleTap,
        onLongPressDown: (details) => _pressKind = details.kind,
        onLongPressStart: _startHold,
        onLongPressEnd: (_) => _endHold(),
        onLongPressCancel: _endHold,
        child: Listener(
          onPointerDown: (event) => _down = event.localPosition,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  key: const ValueKey('video-viewport'),
                  transformationController: widget.zoom,
                  minScale: 1,
                  maxScale: 6,
                  // One finger pans only a zoomed video; otherwise it swipes.
                  panEnabled: !widget.locked && _zoomed,
                  scaleEnabled: !widget.locked,
                  trackpadScrollCausesScale: true,
                  onInteractionStart: _interactionStart,
                  onInteractionUpdate: _interactionUpdate,
                  onInteractionEnd: _interactionEnd,
                  child: widget.viewport,
                ),
              ),
              ...widget.overlays,
              if (_seekTotal > 0 && _seekSide != 0)
                Align(
                  alignment: Alignment(_seekSide * .7, 0),
                  child: IgnorePointer(
                    child: _bubble(
                      Row(
                        key: const ValueKey('video-gesture-seek'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekSide < 0
                                ? Icons.fast_rewind
                                : Icons.fast_forward,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_seekSide < 0 ? '−' : '+'}${_seekTotal ~/ 1000} с',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_holding)
                Align(
                  alignment: const Alignment(0, -.75),
                  child: IgnorePointer(
                    child: _bubble(
                      const Row(
                        key: ValueKey('video-gesture-hold'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('2×'),
                          SizedBox(width: 6),
                          Icon(Icons.fast_forward),
                        ],
                      ),
                    ),
                  ),
                ),
              if (scrubbing)
                Align(
                  alignment: const Alignment(0, -.35),
                  child: IgnorePointer(
                    child: _bubble(
                      Text(
                        key: const ValueKey('video-gesture-scrub'),
                        '${_swipeValue >= _swipeBase ? '+' : '−'}'
                        '${videoTimestamp((_swipeValue - _swipeBase).abs().round())}'
                        '  ·  ${videoTimestamp(_swipeValue.round())}',
                      ),
                    ),
                  ),
                ),
              if (_showLevel)
                Align(
                  alignment: const Alignment(0, -.35),
                  child: IgnorePointer(
                    child: _bubble(
                      SizedBox(
                        width: 200,
                        child: Row(
                          key: const ValueKey('video-gesture-level'),
                          children: [
                            Icon(
                              _levelKind == _Swipe.brightness
                                  ? Icons.brightness_6
                                  : _swipeValue == 0
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: _swipeValue,
                                color: Colors.white,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 44,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text('${(_swipeValue * 100).round()}'),
                              ),
                            ),
                          ],
                        ),
                      ),
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
