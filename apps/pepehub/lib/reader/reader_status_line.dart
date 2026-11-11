import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/pepe_widgets.dart' show pepeCharsPerPage;
import 'reader_window.dart';

/// Book pages in the same unit as the reading statistics: one page is
/// [pepeCharsPerPage] characters, so "page 15 of 52" here and "≈ 52 pages"
/// in the statistics describe the same book.
({int page, int count}) readerBookPages(int length, int absolute) {
  final count = length <= 0 ? 1 : (length / pepeCharsPerPage).ceil();
  final page = absolute ~/ pepeCharsPerPage + 1;
  return (page: page.clamp(1, count), count: count);
}

/// The quiet line under the text, as in ReadEra: battery and time on the
/// left, the book title in the middle, progress and pages on the right.
class ReaderStatusLine extends StatelessWidget {
  final String title, percent, pages;
  final Color ink;
  final double margin;
  final VoidCallback onTap;
  const ReaderStatusLine({
    super.key,
    required this.title,
    required this.percent,
    required this.pages,
    required this.ink,
    required this.margin,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: margin),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 11.5,
          height: 1,
          color: ink.withValues(alpha: .45),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        child: Row(
          children: [
            ReaderClockBattery(ink: ink.withValues(alpha: .45)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(percent, key: const ValueKey('reader-status-percent')),
            const SizedBox(width: 10),
            Text(pages, key: const ValueKey('reader-status-place')),
          ],
        ),
      ),
    ),
  );
}

/// Battery (Android) and clock; refreshed every 30 seconds.
class ReaderClockBattery extends StatefulWidget {
  final Color ink;
  const ReaderClockBattery({super.key, required this.ink});
  @override
  State<ReaderClockBattery> createState() => _ReaderClockBatteryState();
}

class _ReaderClockBatteryState extends State<ReaderClockBattery> {
  Timer? timer;
  DateTime now = DateTime.now();
  ({int level, bool charging})? battery;

  @override
  void initState() {
    super.initState();
    _refresh();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final value = await ReaderWindow.battery();
    if (!mounted) return;
    setState(() {
      now = DateTime.now();
      battery = value;
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    final charge = battery;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (charge != null) ...[
          Tooltip(
            message:
                'Заряд ${charge.level}%${charge.charging ? ', заряжается' : ''}',
            child: CustomPaint(
              key: const ValueKey('reader-status-battery'),
              size: const Size(22, 11),
              painter: _BatteryPainter(
                charge.level / 100,
                widget.ink,
                charge.charging,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Text(time, key: const ValueKey('reader-status-time')),
      ],
    );
  }
}

class _BatteryPainter extends CustomPainter {
  final double level;
  final Color ink;
  final bool charging;
  const _BatteryPainter(this.level, this.ink, this.charging);
  @override
  void paint(Canvas canvas, Size size) {
    final body = Rect.fromLTWH(.5, .5, size.width - 3.5, size.height - 1);
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(2)),
      line,
    );
    canvas.drawRect(
      Rect.fromLTWH(body.right + .5, size.height * .3, 2, size.height * .4),
      Paint()..color = ink,
    );
    final inner = body.deflate(2);
    canvas.drawRect(
      Rect.fromLTWH(
        inner.left,
        inner.top,
        inner.width * level.clamp(0, 1),
        inner.height,
      ),
      Paint()..color = level <= .15 && !charging ? Colors.redAccent : ink,
    );
    if (charging) {
      final c = body.center;
      final bolt = Path()
        ..moveTo(c.dx + 1, c.dy - 4)
        ..lineTo(c.dx - 2.5, c.dy + .5)
        ..lineTo(c.dx, c.dy + .5)
        ..lineTo(c.dx - 1, c.dy + 4)
        ..lineTo(c.dx + 2.5, c.dy - .5)
        ..lineTo(c.dx, c.dy - .5)
        ..close();
      canvas.drawPath(bolt, Paint()..color = Colors.amber);
    }
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter old) =>
      level != old.level || ink != old.ink || charging != old.charging;
}
