import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter keeps a snack bar with an action on screen until it is closed by
/// hand (`persist` defaults to `action != null`). Every message in PepeHub
/// must leave by itself, so each one with an action sets `persist: false`.
void main() {
  test('snack bars with an action disappear on their own', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final match in RegExp(r'\bSnackBar\(').allMatches(source)) {
        var depth = 1, at = match.end;
        while (depth > 0 && at < source.length) {
          final char = source[at++];
          if (char == '(') depth++;
          if (char == ')') depth--;
        }
        final call = source.substring(match.start, at);
        if (call.contains('action:') && !call.contains('persist: false')) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          offenders.add('${file.path}:${line + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
