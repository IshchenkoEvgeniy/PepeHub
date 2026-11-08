import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../notifications/reminder_scheduler.dart';
import 'settings_components.dart';
import '../diagnostics/user_message.dart';

class GoalReminderPreferences {
  final bool enabled;
  final int minute;
  final bool systemNotifications, goals, plans;
  const GoalReminderPreferences({
    this.enabled = false,
    this.minute = 1200,
    this.systemNotifications = false,
    this.goals = true,
    this.plans = true,
  });
  Map<String, dynamic> get json => {
    'enabled': enabled,
    'minute': minute,
    'systemNotifications': systemNotifications,
    'goals': goals,
    'plans': plans,
  };
  static Future<GoalReminderPreferences> load(Repository repository) async {
    try {
      final raw = await repository.meta('goal-reminder');
      final value = raw == null ? const {} : jsonDecode(raw) as Map;
      final minute = value['minute'];
      return GoalReminderPreferences(
        enabled: value['enabled'] == true,
        systemNotifications: value['systemNotifications'] == true,
        goals: value['goals'] != false,
        plans: value['plans'] != false,
        minute: minute is int && minute >= 0 && minute < 1440 ? minute : 1200,
      );
    } on FormatException {
      return const GoalReminderPreferences();
    } on TypeError {
      return const GoalReminderPreferences();
    }
  }

  Future<void> save(Repository repository) =>
      repository.setMeta('goal-reminder', jsonEncode(json));
}

/// Device-local reminders while the application is in the foreground.
/// No library catalog or playback history is loaded by the timer.
class GoalReminderService {
  final Repository repository;
  final bool Function() foreground;
  final bool Function() show;
  final DateTime Function() now;
  Timer? _timer;
  bool _busy = false, _closed = false;
  GoalReminderService(
    this.repository, {
    required this.foreground,
    required this.show,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  void start() {
    unawaited(ReminderScheduler.restore(repository));
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => check());
  }

  Future<void> check() async {
    if (_busy || _closed || !foreground()) return;
    _busy = true;
    try {
      final preferences = await GoalReminderPreferences.load(repository);
      final date = now();
      if (!preferences.enabled ||
          (!preferences.goals && !preferences.plans) ||
          preferences.systemNotifications ||
          date.hour * 60 + date.minute < preferences.minute) {
        return;
      }
      final day = '${date.year}-${date.month}-${date.day}';
      if (await repository.meta('goal-reminder-shown-day') == day) return;
      if (!_closed && foreground() && show()) {
        await repository.setMeta('goal-reminder-shown-day', day);
      }
    } catch (_) {
      // A transient database failure must not interrupt reading or playback.
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
  }
}

class GoalReminderSettings extends StatefulWidget {
  final Repository repository;
  const GoalReminderSettings({super.key, required this.repository});
  @override
  State<GoalReminderSettings> createState() => _GoalReminderSettingsState();
}

class _GoalReminderSettingsState extends State<GoalReminderSettings> {
  GoalReminderPreferences? value;
  String? error;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await GoalReminderPreferences.load(widget.repository);
      if (mounted) setState(() => value = saved);
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    }
  }

  Future<void> _save(GoalReminderPreferences next) async {
    setState(() => saving = true);
    try {
      if (next.systemNotifications || value?.systemNotifications == true) {
        await ReminderScheduler.configure(widget.repository, next.json);
      }
      await next.save(widget.repository);
      if (mounted) {
        setState(() {
          value = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Напоминание не сохранено: ${describeError(e)}');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Напоминания о целях',
        'Ежедневное напоминание в выбранное местное время.',
      ),
      const SettingsNotice(
        'Можно получать системное уведомление даже после закрытия приложения. Android может отложить его ради экономии заряда; после принудительной остановки откройте PepeHub заново. Windows показывает уведомления при входе в учётную запись, в том числе после выхода из сна. Разрешите уведомления PepeHub в настройках системы.',
      ),
      if (error != null) SettingsNotice(error!),
      if (value != null) ...[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Напоминать о чтении и аудиокнигах'),
          value: value!.enabled,
          onChanged: saving
              ? null
              : (enabled) => _save(
                  GoalReminderPreferences(
                    enabled: enabled,
                    minute: value!.minute,
                    systemNotifications: value!.systemNotifications,
                    goals: value!.goals,
                    plans: value!.plans,
                  ),
                ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Системные уведомления'),
          subtitle: const Text(
            'Если выключено — напоминание только внутри приложения',
          ),
          value: value!.systemNotifications,
          onChanged: saving || !ReminderScheduler.supported
              ? null
              : (system) => _save(
                  GoalReminderPreferences(
                    enabled: value!.enabled,
                    minute: value!.minute,
                    systemNotifications: system,
                    goals: value!.goals,
                    plans: value!.plans,
                  ),
                ),
        ),
        for (final field in ['goals', 'plans'])
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              field == 'goals'
                  ? 'Напоминать о ежедневных целях'
                  : 'Напоминать о планах чтения',
            ),
            value: field == 'goals' ? value!.goals : value!.plans,
            onChanged: saving
                ? null
                : (selected) => _save(
                    GoalReminderPreferences(
                      enabled: value!.enabled,
                      minute: value!.minute,
                      systemNotifications: value!.systemNotifications,
                      goals: field == 'goals' ? selected! : value!.goals,
                      plans: field == 'plans' ? selected! : value!.plans,
                    ),
                  ),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Время напоминания'),
          trailing: Text(
            TimeOfDay(
              hour: value!.minute ~/ 60,
              minute: value!.minute % 60,
            ).format(context),
          ),
          onTap: saving
              ? null
              : () async {
                  final time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                      hour: value!.minute ~/ 60,
                      minute: value!.minute % 60,
                    ),
                  );
                  if (time != null && mounted) {
                    await _save(
                      GoalReminderPreferences(
                        enabled: value!.enabled,
                        minute: time.hour * 60 + time.minute,
                        systemNotifications: value!.systemNotifications,
                        goals: value!.goals,
                        plans: value!.plans,
                      ),
                    );
                  }
                },
        ),
      ],
    ],
  );
}
