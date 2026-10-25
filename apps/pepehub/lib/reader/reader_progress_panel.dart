import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../ui/app_theme.dart';

/// Shared, collapsible bottom controls. Only gestures beginning on the panel
/// affect it, so reading and PDF selection retain their vertical gestures.
class ReaderBottomPanel extends StatefulWidget {
  final Widget child;
  const ReaderBottomPanel({super.key, required this.child});
  @override
  State<ReaderBottomPanel> createState() => _ReaderBottomPanelState();
}

class _ReaderBottomPanelState extends State<ReaderBottomPanel> {
  bool hidden = false;
  double travel = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: (_) => travel = 0,
    onVerticalDragUpdate: (event) => travel += event.delta.dy,
    onVerticalDragEnd: (event) {
      final speed = event.primaryVelocity ?? 0;
      if (!hidden && (travel > 24 || speed > 350)) {
        setState(() => hidden = true);
      } else if (hidden && (travel < -20 || speed < -350)) {
        setState(() => hidden = false);
      }
    },
    child: hidden
        ? SizedBox(
            height: 32,
            width: double.infinity,
            child: Center(
              child: IconButton(
                tooltip: 'Показать нижнюю панель',
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => hidden = false),
                icon: const Icon(Icons.keyboard_arrow_up, size: 22),
              ),
            ),
          )
        : widget.child,
  );
}

class ReaderProgressFooter extends StatelessWidget {
  final double value;
  final List<double> ticks;
  final Color ink, accent;
  final ValueChanged<double>? onChanged, onChangeEnd;
  final VoidCallback? onChangeCancel;
  final double step;
  final List<Widget> details, actions;
  const ReaderProgressFooter({
    super.key,
    required this.value,
    this.ticks = const [],
    required this.ink,
    required this.accent,
    this.onChanged,
    this.onChangeEnd,
    this.onChangeCancel,
    this.step = .01,
    required this.details,
    this.actions = const [],
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: ink.withValues(alpha: .12))),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IgnorePointer(
          ignoring: onChangeEnd == null,
          child: ReaderProgressBar(
            value: value,
            ticks: ticks,
            ink: ink,
            accent: accent,
            onChanged: onChanged ?? (_) {},
            onChangeEnd: onChangeEnd ?? (_) {},
            onChangeCancel: onChangeCancel,
            enabled: onChangeEnd != null,
            step: step,
          ),
        ),
        const SizedBox(height: 4),
        IconTheme(
          data: IconThemeData(color: ink.withValues(alpha: .7), size: 22),
          child: Row(
            children: [
              Expanded(
                child: DefaultTextStyle(
                  style: TextStyle(
                    fontFamily: AppFonts.body,
                    fontSize: 12,
                    color: ink.withValues(alpha: .58),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 2,
                    children: details,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ],
    ),
  );
}

/// Thin book progress bar with chapter ticks, as in the reader footer.
class ReaderProgressBar extends StatelessWidget {
  final double value;
  final List<double> ticks;
  final Color ink, accent;
  final ValueChanged<double> onChanged, onChangeEnd;
  final VoidCallback? onChangeCancel;
  final bool enabled;
  final double step;
  const ReaderProgressBar({
    super.key,
    required this.value,
    required this.ticks,
    required this.ink,
    required this.accent,
    required this.onChanged,
    required this.onChangeEnd,
    this.onChangeCancel,
    this.enabled = true,
    this.step = .01,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      double at(Offset p) => (p.dx / width).clamp(0.0, 1.0);
      return Semantics(
        slider: true,
        value: '${(value * 100).round()} процентов книги',
        increasedValue:
            '${((value + step).clamp(0.0, 1.0) * 100).round()} процентов книги',
        decreasedValue:
            '${((value - step).clamp(0.0, 1.0) * 100).round()} процентов книги',
        enabled: enabled,
        onIncrease: enabled && value < 1
            ? () => onChangeEnd((value + step).clamp(0.0, 1.0))
            : null,
        onDecrease: enabled && value > 0
            ? () => onChangeEnd((value - step).clamp(0.0, 1.0))
            : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => onChangeEnd(at(d.localPosition)),
          onHorizontalDragUpdate: (d) => onChanged(at(d.localPosition)),
          onHorizontalDragEnd: (d) => onChangeEnd(at(d.localPosition)),
          onHorizontalDragCancel: onChangeCancel,
          child: SizedBox(
            height: 22,
            child: CustomPaint(
              painter: _BookProgressPainter(value, ink, accent),
              foregroundPainter: _BookProgressPainter(
                value,
                ink,
                accent,
                thumb: true,
              ),
              child: RepaintBoundary(
                child: CustomPaint(painter: ReaderBookTicksPainter(ticks, ink)),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _BookProgressPainter extends CustomPainter {
  final double value;
  final Color ink, accent;
  final bool thumb;
  const _BookProgressPainter(
    this.value,
    this.ink,
    this.accent, {
    this.thumb = false,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * value.clamp(0, 1);
    if (thumb) {
      canvas.drawCircle(Offset(x, 11), 8, Paint()..color = ink);
      return;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 9, size.width, 4),
        const Radius.circular(2),
      ),
      Paint()..color = ink.withValues(alpha: .14),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 9, x, 4),
        const Radius.circular(2),
      ),
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(covariant _BookProgressPainter old) =>
      value != old.value ||
      ink != old.ink ||
      accent != old.accent ||
      thumb != old.thumb;
}

class ReaderBookTicksPainter extends CustomPainter {
  final List<double> ticks;
  final Color ink;
  const ReaderBookTicksPainter(this.ticks, this.ink);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ink.withValues(alpha: .28)
      ..strokeWidth = 2;
    for (final tick in ticks) {
      final x = size.width * tick;
      canvas.drawLine(Offset(x, 6), Offset(x, 16), paint);
    }
  }

  @override
  bool shouldRepaint(covariant ReaderBookTicksPainter old) =>
      ink != old.ink || !listEquals(ticks, old.ticks);
}
