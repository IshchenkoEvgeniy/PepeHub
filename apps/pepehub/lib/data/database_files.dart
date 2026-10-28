import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:uuid/uuid.dart';

const currentDatabaseVersion = 4;

/// Frozen at the name introduced by schema 3: later versions migrate in place.
const currentDatabaseFilename = 'pepehub-v3.sqlite';

/// Runs on a background isolate before Drift opens the database. VACUUM INTO
/// includes committed WAL pages; copying a live SQLite file would not.
String prepareDatabaseFiles(String directoryPath) {
  final directory = Directory(directoryPath)..createSync(recursive: true);
  final target = File(p.join(directory.path, currentDatabaseFilename));
  final legacy = File(p.join(directory.path, 'pepehub.sqlite'));
  if (!target.existsSync() && legacy.existsSync()) {
    final source = sqlite.sqlite3.open(
      legacy.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final version =
          source.select('PRAGMA user_version').single.values.first as int;
      // 1–2: the original 0.4 database; later versions: a restored backup.
      if (version < 1 || version > currentDatabaseVersion) {
        throw StateError(
          'Неизвестная версия исходной базы: $version. Данные сохранены.',
        );
      }
      _snapshot(source, target.path);
    } finally {
      source.close();
    }
  }
  if (target.existsSync()) {
    final source = sqlite.sqlite3.open(
      target.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      final version =
          source.select('PRAGMA user_version').single.values.first as int;
      if (version > currentDatabaseVersion) {
        throw StateError(
          'База создана более новой версией PepeHub ($version). Обновите приложение.',
        );
      }
      if (version > 0 && version < currentDatabaseVersion) {
        final backups = Directory(p.join(directory.path, 'backups'))
          ..createSync();
        _snapshot(
          source,
          p.join(
            backups.path,
            'before-v$currentDatabaseVersion-${const Uuid().v4()}.sqlite',
          ),
        );
      }
    } finally {
      source.close();
    }
  }
  return target.path;
}

void _snapshot(sqlite.Database source, String targetPath) {
  final temporary = File('$targetPath.${const Uuid().v4()}.partial');
  try {
    source.execute('VACUUM INTO ?', [temporary.path]);
    final copy = sqlite.sqlite3.open(
      temporary.path,
      mode: sqlite.OpenMode.readOnly,
    );
    try {
      if (copy.select('PRAGMA quick_check').single.values.first != 'ok') {
        throw StateError('Проверка резервной копии не пройдена');
      }
    } finally {
      copy.close();
    }
    if (File(targetPath).existsSync()) {
      throw StateError(
        'Файл базы уже существует. Повторите открытие приложения.',
      );
    }
    temporary.renameSync(targetPath);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
