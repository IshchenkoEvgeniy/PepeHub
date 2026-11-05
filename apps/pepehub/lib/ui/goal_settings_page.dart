import 'package:flutter/material.dart';

import '../audio/statistics_export.dart';
import '../data/repository.dart';
import '../notifications/reminder_scheduler.dart';
import 'goal_reminders.dart';
import 'settings_components.dart';

/// All entry points edit the same goals through this screen.
class GoalSettingsPage extends StatefulWidget {
  final Repository repository;
  const GoalSettingsPage({super.key, required this.repository});
  @override
  State<GoalSettingsPage> createState() => _GoalSettingsPageState();
}

class _GoalSettingsPageState extends State<GoalSettingsPage> {
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
          error = '$e';
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
      if (mounted) setState(() => error = 'Изменение не сохранено: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _minutes(String kind, String title, int value, int max, int step) =>
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                Expanded(child: Text(value == 0 ? 'Без цели' : '$value мин')),
                IconButton(
                  tooltip: 'Уменьшить: $title',
                  onPressed: saving || value == 0
                      ? null
                      : () => _save(kind, (value - step).clamp(0, max)),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: 'Увеличить: $title',
                  onPressed: saving || value == max
                      ? null
                      : () => _save(kind, (value + step).clamp(0, max)),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Цели')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SettingsNotice(
                'Общие цели для всех книг. 0 — без цели. Музыка не входит в цель прослушивания аудиокниг.',
              ),
              if (error != null) SettingsNotice(error!),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Напоминания о цели и плане'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Напоминания')),
                      body: ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          GoalReminderSettings(repository: widget.repository),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SettingsGroup(
                children: [
                  _minutes('reading', 'Чтение в день', reading, 1440, 5),
                  _minutes(
                    'daily',
                    'Прослушивание в день',
                    listening.dailyMinutes,
                    1440,
                    5,
                  ),
                  _minutes(
                    'weekly',
                    'Прослушивание в неделю',
                    listening.weeklyMinutes,
                    10080,
                    30,
                  ),
                ],
              ),
            ],
          ),
  );
}
