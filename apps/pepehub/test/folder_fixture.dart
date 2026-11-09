import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';

/// An in-memory database with a temporary folder of book files.
class FolderFixture {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db);
  late Directory base, root;

  Future<void> open() async {
    base = await Directory.systemTemp.createTemp('pepe-folder-test-');
    root = await Directory(p.join(base.path, 'shared')).create();
  }

  Future<void> close() async {
    await db.close();
    await base.delete(recursive: true);
  }
}
