import 'dart:io';

import 'package:path/path.dart' as p;

/// Material Icons font shipped with the Flutter SDK that runs the tests.
///
/// `flutter_tester` lives in `<flutter>/bin/cache/artifacts/engine/<platform>/`,
/// next to `artifacts/material_fonts`, so this works with the repo-local SDK in
/// `.tools/flutter` and with any other installation (GitHub Actions, a global
/// SDK). FLUTTER_ROOT and the repo-local path are fallbacks.
final String materialIconsFont = () {
  const name = 'MaterialIcons-Regular.otf';
  final candidates = <String>[
    p.join(
      p.dirname(p.dirname(p.dirname(Platform.resolvedExecutable))),
      'material_fonts',
      name,
    ),
    if (Platform.environment['FLUTTER_ROOT'] case final String root)
      p.join(root, 'bin', 'cache', 'artifacts', 'material_fonts', name),
    p.join(
      '..',
      '..',
      '.tools',
      'flutter',
      'bin',
      'cache',
      'artifacts',
      'material_fonts',
      name,
    ),
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('Не найден $name. Проверено:\n${candidates.join('\n')}');
}();
