import 'dart:async';

import 'package:flutter/widgets.dart';

bool _usableSize(Size value) =>
    value.width.isFinite &&
    value.height.isFinite &&
    value.width > 0 &&
    value.height > 0;

/// Display metrics may be unavailable at startup or stale during rotation.
/// Keep a usable reference while Android changes system bar visibility.
class ReaderScreenGeometry {
  Size? _reference;
  bool? _landscape;

  Size resolve({required Size display, required Size window}) {
    final landscape = window.width > window.height;
    var candidate = display;
    if (_usableSize(candidate) &&
        (candidate.width > candidate.height) != landscape) {
      candidate = Size(candidate.height, candidate.width);
    }
    if (_usableSize(candidate) &&
        candidate.width >= window.width &&
        candidate.height >= window.height) {
      _reference = candidate;
      _landscape = landscape;
    } else if (_reference == null ||
        !_usableSize(_reference!) ||
        _landscape != landscape) {
      _reference = window;
      _landscape = landscape;
    }
    return _reference!;
  }
}

/// Keeps measured text visible during a desktop resize, then measures the
/// settled size once. Transient controls are painted outside this frame.
class ReaderLayoutFrame extends StatefulWidget {
  final Widget Function(BuildContext, BoxConstraints) builder;
  final VoidCallback? onResize;
  // Android's Flutter view can grow when system bars disappear. A reading
  // page is measured against the display, independently of that view.
  final Size? pageSize;
  const ReaderLayoutFrame({
    super.key,
    required this.builder,
    this.onResize,
    this.pageSize,
  });
  @override
  State<ReaderLayoutFrame> createState() => _ReaderLayoutFrameState();
}

class _ReaderLayoutFrameState extends State<ReaderLayoutFrame> {
  Size? size, pending;
  Timer? timer;
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final requested = widget.pageSize ?? box.biggest;
      final next = _usableSize(requested) ? requested : size ?? box.biggest;
      size ??= next;
      if (pending != next) {
        pending = next;
        timer?.cancel();
        if (next != size) {
          timer = Timer(const Duration(milliseconds: 180), () {
            if (!mounted) return;
            widget.onResize?.call();
            setState(() => size = pending);
          });
        }
      }
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: size!.width,
          maxWidth: size!.width,
          minHeight: size!.height,
          maxHeight: size!.height,
          child: SizedBox(
            width: size!.width,
            height: size!.height,
            child: widget.builder(context, BoxConstraints.tight(size!)),
          ),
        ),
      );
    },
  );
}
