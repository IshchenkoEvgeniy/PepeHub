import 'dart:async';

import 'package:flutter/widgets.dart';

/// Keeps measured text visible during a desktop resize, then measures the
/// settled size once. Transient controls are painted outside this frame.
class ReaderLayoutFrame extends StatefulWidget {
  final Widget Function(BuildContext, BoxConstraints) builder;
  final VoidCallback? onResize;
  const ReaderLayoutFrame({super.key, required this.builder, this.onResize});
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
      final next = box.biggest;
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
