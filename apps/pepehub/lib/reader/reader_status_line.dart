import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/pepe_widgets.dart' show pepeCharsPerPage;
import 'reader_window.dart';

/// Book pages as screens: [charsPerScreen] is the measured text of one screen
/// with the current font and window, so turning a page moves the number by
/// one and «37 of 412» means screens left to turn. Until the first layout is
/// measured, a page is [pepeCharsPerPage] characters, as in the statistics.
({int page, int count}) readerBookPages(
  int length,
  int absolute, {
  double? charsPerScreen,
}) {
  final size = readerScreenSize(charsPerScreen);
  final count = length <= 0 ? 1 : (length / size).ceil();
  final page = (absolute / size).floor() + 1;
  return (page: page.clamp(1, count), count: count);
}

/// Characters of one screen: the measured value, or [pepeCharsPerPage]
/// until a layout has been measured.
double readerScreenSize(double? charsPerScreen) =>
    charsPerScreen != null && charsPerScreen >= 50
    ? charsPerScreen
    : pepeCharsPerPage.toDouble();

/// A laid-out screen in chapter coordinates.
typedef ReaderScreen = ({int chapter, int start, int end});

/// Book pages counted in real screens. Screens the viewport has laid out are
/// counted exactly, so a page turn moves the number by one and a short
/// chapter end is a page of its own (every chapter starts on a new screen).
/// Text not laid out yet is estimated at [size] characters a screen.
class ReaderScreens {
  final List<int> lengths;
  final List<ReaderScreen> laid;

  /// The chapter of the last laid-out screen is laid out to its end.
  final bool complete;
  final double size;
  final _first = <int, int>{}, _count = <int, int>{};
  final _before = <int>[0];

  ReaderScreens(
    this.lengths,
    this.laid, {
    required this.complete,
    required this.size,
  }) {
    for (var i = 0; i < laid.length; i++) {
      final chapter = laid[i].chapter;
      _first.putIfAbsent(chapter, () => i);
      _count[chapter] = (_count[chapter] ?? 0) + 1;
    }
    for (var c = 0; c < lengths.length; c++) {
      _before.add(_before.last + _pagesOf(c));
    }
  }

  int get count => math.max(1, _before.last);

  int _estimate(int chars) => chars <= 0 ? 0 : (chars / size).ceil();

  int _prefix(int c) => _estimate(laid[_first[c]!].start);

  bool _laidToEnd(int c) => _first[c]! + _count[c]! < laid.length || complete;

  int _pagesOf(int c) {
    final first = _first[c];
    if (first == null) return math.max(1, _estimate(lengths[c]));
    final n = _count[c]!;
    final suffix = _laidToEnd(c)
        ? 0
        : _estimate(lengths[c] - laid[first + n - 1].end);
    return _prefix(c) + n + suffix;
  }

  /// 1-based page of the place [offset] in [chapter].
  int page(int chapter, int offset) {
    if (lengths.isEmpty) return 1;
    final c = chapter.clamp(0, lengths.length - 1);
    final pages = _before[c + 1] - _before[c];
    final first = _first[c];
    int local;
    if (first == null) {
      local = (offset / size).floor();
    } else if (offset < laid[first].start) {
      local = math.min((offset / size).floor(), _prefix(c) - 1);
    } else {
      final lastIndex = first + _count[c]! - 1;
      var lo = first, hi = lastIndex;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (laid[mid].start <= offset) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final last = laid[lastIndex];
      local = lo == lastIndex && !_laidToEnd(c) && offset >= last.end
          ? _prefix(c) + lo - first + 1 + ((offset - last.end) / size).floor()
          : _prefix(c) + lo - first;
    }
    return _before[c] + local.clamp(0, pages - 1) + 1;
  }
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
