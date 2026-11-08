import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/diagnostics/error_log.dart';
import 'package:pepehub/diagnostics/user_message.dart';

class _AppException implements Exception {
  final String message;
  _AppException(this.message);
  @override
  String toString() => 'UpdateException: $message';
}

void main() {
  group('describeError', () {
    test('keeps messages the app wrote in Russian', () {
      expect(describeError(StateError('Файл изменился')), 'Файл изменился');
      expect(
        describeError(TimeoutException('Аудиодвижок не ответил')),
        'Аудиодвижок не ответил',
      );
      expect(
        describeError(const SocketException('Ретранслятор недоступен')),
        'Ретранслятор недоступен',
      );
      expect(
        describeError(_AppException('Помощник не запустился')),
        'Помощник не запустился',
      );
      expect(describeError('Уже готовый текст'), 'Уже готовый текст');
    });

    test('translates system failures instead of showing raw exceptions', () {
      expect(
        describeError(
          const FileSystemException(
            'Cannot open file',
            '/books/a.epub',
            OSError('No such file or directory', 2),
          ),
        ),
        'Файл или папка не найдены: /books/a.epub.',
      );
      expect(
        describeError(
          const FileSystemException('write', '/x', OSError('No space', 28)),
        ),
        'Недостаточно свободного места на диске.',
      );
      expect(
        describeError(TimeoutException('Future not completed')),
        'Истекло время ожидания. Попробуйте ещё раз.',
      );
      expect(
        describeError(const FormatException('Unexpected character')),
        'Файл повреждён или имеет неподдерживаемый формат.',
      );
      expect(describeError(Exception('boom')), contains('журнал ошибок'));
      expect(describeError(null), 'Неизвестная ошибка');
    });
  });

  group('ErrorLog', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('error-log-');
      ErrorLog.attach(dir);
    });
    tearDown(() async {
      await ErrorLog.clear();
      await dir.delete(recursive: true);
    });

    test('writes entries with context and stack, and clears them', () async {
      ErrorLog.record(StateError('сбой'), StackTrace.current, context: 'тест');
      final text = await ErrorLog.read();
      expect(text, contains('тест: Bad state: сбой'));
      expect(text, contains('diagnostics_test.dart'));
      await ErrorLog.clear();
      expect((await ErrorLog.read()).trim(), isEmpty);
    });

    test('repeated failures with the same key are written once', () async {
      for (var i = 0; i < 5; i++) {
        ErrorLog.record(StateError('повтор'), null, once: 'same-key');
      }
      final text = await ErrorLog.read();
      expect('повтор'.allMatches(text).length, 1);
    });

    test('describeError keeps the raw exception in the log', () async {
      // A fresh instance: the same error object is logged only once.
      final error = FormatException('Unknown tag in ${dir.path}');
      describeError(error);
      describeError(error);
      final text = await ErrorLog.read();
      expect('Unknown tag'.allMatches(text).length, 1);
    });
  });
}
