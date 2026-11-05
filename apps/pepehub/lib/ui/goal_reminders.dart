import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'settings_components.dart';

class GoalReminderPreferences {
  final bool enabled;
  final int minute;
  const GoalReminderPreferences({this.enabled = false, this.minute = 1200});
  static Future<GoalReminderPreferences> load(Repository repository) async {
    try {
      final raw = await repository.meta('goal-reminder');
      final value = raw == null ? const {} : jsonDecode(raw) as Map;
      final minute = value['minute'];
      return GoalReminderPreferences(
        enabled: value['enabled'] == true,
        minute: minute is int && minute >= 0 && minute < 1440 ? minute : 1200,
      );
    } on FormatException {
      return const GoalReminderPreferences();
    } on TypeError {
      return const GoalReminderPreferences();
    }
  }

  Future<void> save(Repository repository) => repository.setMeta(
    'goal-reminder',
    jsonEncode({'enabled': enabled, 'minute': minute}),
  );
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
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => check());
  }

  Future<void> check() async {
    if (_busy || _closed || !foreground()) return;
    _busy = true;
    try {
      final preferences = await GoalReminderPreferences.load(repository);
      final date = now();
      if (!preferences.enabled ||
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
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _save(GoalReminderPreferences next) async {
    setState(() => saving = true);
    try {
      await next.save(widget.repository);
      if (mounted) {
        setState(() {
          value = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Напоминание не сохранено: $e');
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
        'Напоминания показываются внутри открытого приложения, один раз в день. Если приложение было закрыто, напоминание появится при открытии после выбранного времени. Системных уведомлений при закрытом приложении пока нет.',
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
                      ),
                    );
                  }
                },
        ),
      ],
    ],
  );
}
