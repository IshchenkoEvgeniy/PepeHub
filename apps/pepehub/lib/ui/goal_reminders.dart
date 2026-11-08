import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  GoalReminderPreferences copyWith({
    bool? enabled,
    int? minute,
    bool? systemNotifications,
    bool? goals,
    bool? plans,
  }) => GoalReminderPreferences(
    enabled: enabled ?? this.enabled,
    minute: minute ?? this.minute,
    systemNotifications: systemNotifications ?? this.systemNotifications,
    goals: goals ?? this.goals,
    plans: plans ?? this.plans,
  );

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
  final bool heading;
  const GoalReminderSettings({
    super.key,
    required this.repository,
    this.heading = true,
  });
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

  String get _platformNote => Platform.isAndroid
      ? 'Android может отложить уведомление ради экономии заряда. После принудительной остановки откройте PepeHub заново.'
      : Platform.isWindows
      ? 'Windows показывает уведомление после входа в учётную запись, в том числе после выхода из сна.'
      : 'Системные уведомления на этой платформе недоступны — напоминание появится в открытом приложении.';

  Future<void> _pickTime(GoalReminderPreferences current) async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: current.minute ~/ 60,
        minute: current.minute % 60,
      ),
    );
    if (time != null && mounted) {
      await _save(current.copyWith(minute: time.hour * 60 + time.minute));
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = value;
    final active = current != null && current.enabled && !saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.heading)
          const SettingsHeading(
            'Напоминания',
            'Ежедневное напоминание в выбранное местное время.',
          ),
        if (error != null) SettingsNotice(error!),
        if (current == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (current != null)
          SettingsGroup(
            children: [
              SwitchListTile(
                key: const ValueKey('goal-reminder-enabled'),
                title: const Text('Напоминать о чтении и аудиокнигах'),
                value: current.enabled,
                onChanged: saving
                    ? null
                    : (enabled) => _save(current.copyWith(enabled: enabled)),
              ),
              ListTile(
                enabled: active,
                title: const Text('Время напоминания'),
                trailing: Text(
                  TimeOfDay(
                    hour: current.minute ~/ 60,
                    minute: current.minute % 60,
                  ).format(context),
                ),
                onTap: active ? () => _pickTime(current) : null,
              ),
              for (final field in ['goals', 'plans'])
                CheckboxListTile(
                  title: Text(
                    field == 'goals' ? 'О ежедневных целях' : 'О планах чтения',
                  ),
                  value: field == 'goals' ? current.goals : current.plans,
                  onChanged: active
                      ? (selected) => _save(
                          field == 'goals'
                              ? current.copyWith(goals: selected)
                              : current.copyWith(plans: selected),
                        )
                      : null,
                ),
              SwitchListTile(
                title: const Text('Системные уведомления'),
                subtitle: Text(
                  ReminderScheduler.supported
                      ? 'Приходят и при закрытом приложении. $_platformNote'
                      : _platformNote,
                ),
                value: current.systemNotifications,
                onChanged: active && ReminderScheduler.supported
                    ? (system) =>
                          _save(current.copyWith(systemNotifications: system))
                    : null,
              ),
            ],
          ),
      ],
    );
  }
}
