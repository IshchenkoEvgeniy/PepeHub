import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/statistics_export.dart';
import '../data/repository.dart';
import '../notifications/reminder_scheduler.dart';
import 'goal_reminders.dart';
import 'settings_components.dart';
import '../diagnostics/user_message.dart';

/// Formats a goal in minutes: «Без цели», «45 мин», «1 ч 30 мин».
String goalMinutesLabel(int minutes) {
  if (minutes == 0) return 'Без цели';
  final hours = minutes ~/ 60, rest = minutes % 60;
  if (hours == 0) return '$rest мин';
  return rest == 0 ? '$hours ч' : '$hours ч $rest мин';
}

/// Goals for reading and listening. Every entry point edits the same values.
class GoalSettings extends StatefulWidget {
  final Repository repository;
  const GoalSettings({super.key, required this.repository});
  @override
  State<GoalSettings> createState() => _GoalSettingsState();
}

class _GoalSettingsState extends State<GoalSettings> {
  int reading = 30;
  ListeningGoals listening = const ListeningGoals();
  bool loading = true, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.repository.meta('reading-daily-goal');
      ListeningGoals goals;
      try {
        goals = await ListeningGoals.load(widget.repository);
      } on FormatException {
        goals = const ListeningGoals();
      } on TypeError {
        goals = const ListeningGoals();
      }
      if (!mounted) return;
      setState(() {
        reading = (int.tryParse(value ?? '') ?? 30).clamp(0, 1440);
        listening = ListeningGoals(
          dailyMinutes: goals.dailyMinutes.clamp(0, 1440),
          weeklyMinutes: goals.weeklyMinutes.clamp(0, 10080),
        );
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = describeError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _save(String kind, int value) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      if (kind == 'reading') {
        await widget.repository.setMeta('reading-daily-goal', '$value');
        if (mounted) setState(() => reading = value);
      } else {
        final next = ListeningGoals(
          dailyMinutes: kind == 'daily' ? value : listening.dailyMinutes,
          weeklyMinutes: kind == 'weekly' ? value : listening.weeklyMinutes,
        );
        await next.save(widget.repository);
        if (mounted) setState(() => listening = next);
      }
      if (mounted) setState(() => error = null);
      await ReminderScheduler.restore(widget.repository);
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Изменение не сохранено: ${describeError(e)}');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _custom(String kind, String title, int value, int max) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) =>
          _GoalInputDialog(kind: kind, title: title, value: value, max: max),
    );
    if (result != null && result != value) await _save(kind, result);
  }

  Widget _goal(
    String kind,
    String title,
    int value,
    int max,
    List<int> presets,
  ) {
    final custom = !presets.contains(value);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(goalMinutesLabel(value)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                ChoiceChip(
                  key: ValueKey('goal:$kind:$preset'),
                  label: Text(
                    preset == 0 ? 'Без цели' : goalMinutesLabel(preset),
                  ),
                  selected: value == preset,
                  onSelected: saving ? null : (_) => _save(kind, preset),
                ),
              ChoiceChip(
                key: ValueKey('goal:$kind:custom'),
                label: Text(custom ? goalMinutesLabel(value) : 'Своё…'),
                selected: custom,
                onSelected: saving
                    ? null
                    : (_) => _custom(kind, title, value, max),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => loading
      ? const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) SettingsNotice(error!),
            SettingsGroup(
              children: [
                _goal('reading', 'Чтение в день', reading, 1440, const [
                  0,
                  15,
                  30,
                  60,
                  90,
                ]),
                _goal(
                  'daily',
                  'Аудиокниги в день',
                  listening.dailyMinutes,
                  1440,
                  const [0, 15, 30, 60, 90],
                ),
                _goal(
                  'weekly',
                  'Аудиокниги в неделю',
                  listening.weeklyMinutes,
                  10080,
                  const [0, 120, 180, 300, 420],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
              child: Text(
                'Цели общие для всех книг. Музыка не учитывается в цели аудиокниг.',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ),
          ],
        );
}

/// Asks for a goal in minutes. Owns its controller, so the text field stays
/// valid while the dialog animates out.
class _GoalInputDialog extends StatefulWidget {
  final String kind, title;
  final int value, max;
  const _GoalInputDialog({
    required this.kind,
    required this.title,
    required this.value,
    required this.max,
  });
  @override
  State<_GoalInputDialog> createState() => _GoalInputDialogState();
}

class _GoalInputDialogState extends State<_GoalInputDialog> {
  late final controller = TextEditingController(
    text: widget.value == 0 ? '' : '${widget.value}',
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(controller.text.trim()) ?? 0;
    Navigator.pop(context, parsed.clamp(0, widget.max));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: ValueKey('goal-input:${widget.kind}'),
      controller: controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: 'Минут',
        helperText: '0 — без цели, максимум ${widget.max}',
      ),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Сохранить')),
    ],
  );
}

/// Goals and reminders on one screen; also opened from statistics and plans.
class GoalSettingsPage extends StatelessWidget {
  final Repository repository;
  const GoalSettingsPage({super.key, required this.repository});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Цели и напоминания')),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [GoalAndReminderSettings(repository: repository)],
        ),
      ),
    ),
  );
}

/// Content shared by the settings section and [GoalSettingsPage].
class GoalAndReminderSettings extends StatelessWidget {
  final Repository repository;
  const GoalAndReminderSettings({super.key, required this.repository});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Цели и напоминания',
        'Дневные и недельные цели и ежедневное напоминание о них.',
      ),
      const SettingsSubheading('Цели'),
      GoalSettings(repository: repository),
      const SettingsSubheading('Напоминание'),
      GoalReminderSettings(repository: repository, heading: false),
    ],
  );
}
