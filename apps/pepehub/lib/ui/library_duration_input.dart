import 'package:flutter/material.dart';

/// Storage stays in the card's units; people enter clock time instead.
class LibraryDurationInput extends StatefulWidget {
  final TextEditingController controller;
  final String label, unit;
  final bool enabled;
  const LibraryDurationInput({
    super.key,
    required this.controller,
    required this.label,
    required this.unit,
    required this.enabled,
  });
  @override
  State<LibraryDurationInput> createState() => _LibraryDurationInputState();
}

class _LibraryDurationInputState extends State<LibraryDurationInput> {
  late final hours = TextEditingController();
  late final minutes = TextEditingController();
  late final seconds = TextEditingController();
  bool updating = false;
  @override
  void initState() {
    super.initState();
    _read();
    widget.controller.addListener(_read);
  }

  void _read() {
    if (updating) return;
    final value = double.tryParse(widget.controller.text);
    final total = value == null || !value.isFinite || value < 0
        ? null
        : (value * (widget.unit == 'hours' ? 3600 : 60)).round();
    hours.text = total == null ? '' : '${total ~/ 3600}';
    minutes.text = total == null ? '' : '${total ~/ 60 % 60}';
    seconds.text = total == null ? '' : '${total % 60}';
  }

  void _write() {
    final h = int.tryParse(hours.text),
        m = int.tryParse(minutes.text),
        s = int.tryParse(seconds.text);
    // Invalid input stays in the visible form and is rejected by its validator.
    if ([
          hours,
          minutes,
          seconds,
        ].any((c) => c.text.isNotEmpty && int.tryParse(c.text) == null) ||
        (h ?? 0) < 0 ||
        (m ?? 0) < 0 ||
        (m ?? 0) > 59 ||
        (s ?? 0) < 0 ||
        (s ?? 0) > 59) {
      return;
    }
    updating = true;
    widget.controller.text =
        [hours, minutes, seconds].every((c) => c.text.isEmpty)
        ? ''
        : '${((h ?? 0) * 3600 + (m ?? 0) * 60 + (s ?? 0)) / (widget.unit == 'hours' ? 3600 : 60)}';
    updating = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_read);
    hours.dispose();
    minutes.dispose();
    seconds.dispose();
    super.dispose();
  }

  Widget _part(TextEditingController controller, String label, {int? max}) =>
      Expanded(
        child: TextFormField(
          controller: controller,
          enabled: widget.enabled,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label, hintText: '0'),
          onChanged: (_) => _write(),
          validator: (text) {
            if (text == null || text.isEmpty) return null;
            final number = int.tryParse(text);
            if (number == null || number < 0 || number > (max ?? 99999)) {
              return max == null ? 'Введите часы' : 'От 0 до $max';
            }
            return null;
          },
        ),
      );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 10),
        Row(
          children: [
            _part(hours, 'Часы'),
            const SizedBox(width: 8),
            _part(minutes, 'Минуты', max: 59),
            const SizedBox(width: 8),
            _part(seconds, 'Секунды', max: 59),
          ],
        ),
      ],
    ),
  );
}
