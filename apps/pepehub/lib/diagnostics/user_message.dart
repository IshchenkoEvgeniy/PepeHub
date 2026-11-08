import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'error_log.dart';

final _logged = Expando<bool>('describeError');

/// Short Russian explanation of [error] for the interface.
///
/// The original exception is written once to [ErrorLog], so details are not
/// lost when the user only sees the friendly text.
String describeError(Object? error) {
  if (error == null) return 'Неизвестная ошибка';
  if (error is String) return error;
  if (error is! num && error is! bool && _logged[error] != true) {
    _logged[error] = true;
    ErrorLog.record(
      error,
      error is Error ? error.stackTrace : null,
      context: 'shown to user',
    );
  }
  return _describe(error);
}

String _describe(Object error) {
  if (error is TimeoutException) {
    final message = error.message ?? '';
    return _isRussian(message)
        ? message
        : 'Истекло время ожидания. Попробуйте ещё раз.';
  }
  // The app throws these with its own Russian text; keep it.
  if (error is HttpException && _isRussian(error.message)) {
    return error.message;
  }
  if (error is SocketException &&
      error.osError == null &&
      _isRussian(error.message)) {
    return error.message;
  }
  if (error is FileSystemException &&
      error.osError == null &&
      _isRussian(error.message)) {
    return error.message;
  }
  if (error is SocketException || error is HttpException) {
    return 'Нет связи с сервером или устройством. Проверьте подключение к сети.';
  }
  if (error is FileSystemException) {
    final where = error.path == null || error.path!.isEmpty
        ? ''
        : ': ${error.path}';
    return switch (error.osError?.errorCode) {
      28 || 39 || 112 => 'Недостаточно свободного места на диске.',
      5 ||
      13 ||
      1 => 'Нет доступа к файлу или папке$where. Проверьте разрешения.',
      2 || 3 => 'Файл или папка не найдены$where.',
      32 ||
      33 => 'Файл занят другой программой$where. Закройте её и повторите.',
      _ => 'Не удалось прочитать или записать файл$where.',
    };
  }
  if (error is PlatformException) {
    final message = error.message?.trim();
    return message == null || message.isEmpty
        ? 'Системная ошибка (${error.code}).'
        : message;
  }
  if (error is StateError) return error.message;
  if (error is FormatException) {
    return _isRussian(error.message)
        ? error.message
        : 'Файл повреждён или имеет неподдерживаемый формат.';
  }
  if (error is ArgumentError) {
    final message = '${error.message ?? ''}';
    return _isRussian(message) ? message : 'Некорректное значение.';
  }
  if (error is UnsupportedError) {
    final message = error.message ?? '';
    return _isRussian(message) ? message : 'Действие не поддерживается.';
  }
  if (error is OutOfMemoryError) {
    return 'Недостаточно памяти для этого действия.';
  }
  if (error is Error) {
    return 'Внутренняя ошибка приложения. Подробности записаны в журнал ошибок.';
  }
  final text = '$error'.trim().replaceFirst(
    RegExp(r'^(?:\w*(?:Exception|Error)|Bad state): '),
    '',
  );
  if (text.isEmpty) return 'Неизвестная ошибка';
  return _isRussian(text)
      ? text
      : 'Не удалось выполнить действие. Подробности записаны в журнал ошибок.';
}

bool _isRussian(String text) => RegExp('[А-Яа-яЁё]').hasMatch(text);
