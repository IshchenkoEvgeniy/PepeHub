import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../data/repository.dart';

class ReminderScheduler {
  static const channel = MethodChannel('app.pepehub/reminders');
  static bool get supported => Platform.isAndroid || Platform.isWindows;
  static Future<void> configure(
    Repository repository,
    Map<String, dynamic> value, {
    bool requestPermission = true,
  }) async {
    if (!supported) {
      throw UnsupportedError(
        'Системные уведомления доступны на Android и Windows',
      );
    }
    final minute = value['minute'];
    if (minute is! int || minute < 0 || minute >= 1440) {
      throw ArgumentError('Некорректное время');
    }
    final enabled =
        value['enabled'] == true && value['systemNotifications'] == true;
    final goals = value['goals'] != false, plans = value['plans'] != false;
    final parts = <String>[];
    if (goals) {
      final reading =
          int.tryParse(await repository.meta('reading-daily-goal') ?? '') ?? 30;
      final audio = jsonDecode(
        await repository.meta('audio-listening-goals') ?? '{"dailyMinutes":30}',
      ) as Map;
      parts.add(
        'Цели на день: чтение $reading мин, аудио ${audio['dailyMinutes'] ?? 30} мин.',
      );
    }
    if (plans) {
      final saved = await repository.metadataPrefixes(['reading-plan:']);
      final titles = {
        for (final book in await repository.bookHeaders()) book.id: book.title,
      };
      final names = [
        for (final key in saved.keys)
          if (titles.containsKey(key.substring(13))) titles[key.substring(13)]!,
      ];
      parts.add(
        names.isEmpty
            ? 'Загляните в план чтения.'
            : 'Планы чтения: ${names.take(3).join(', ')}${names.length > 3 ? ' и ещё ${names.length - 3}' : ''}.',
      );
    }
    if (enabled && !goals && !plans) {
      throw ArgumentError('Выберите цель или план');
    }
    final body = parts.join(' ');
    final config = <String, dynamic>{
      'enabled': enabled,
      'minute': minute,
      'body': body.length > 800 ? '${body.substring(0, 797)}…' : body,
      'requestPermission': requestPermission,
    };
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('configure', config);
    } else {
      final root = await getApplicationSupportDirectory();
      final dir = Directory('${root.path}/reminders');
      await dir.create(recursive: true);
      final script = File('${dir.path}/reminder.ps1');
      await script.writeAsString(
        '\ufeff${await rootBundle.loadString('assets/reminders/windows-reminder.ps1')}',
        flush: true,
      );
      await File('${dir.path}/reminder.json').writeAsString(
        jsonEncode({...config, 'exe': Platform.resolvedExecutable}),
        flush: true,
      );
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Configure',
      ]);
      if (result.exitCode != 0) {
        throw StateError('Windows не сохранила уведомление: ${result.stderr}');
      }
    }
  }

  static Future<void> restore(Repository repository) async {
    try {
      final raw = await repository.meta('goal-reminder');
      if (raw == null) return;
      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (data['systemNotifications'] == true) {
        await configure(repository, data, requestPermission: false);
      }
    } catch (_) {
      /* OS permission/settings can change while the app is closed. */
    }
  }
}
