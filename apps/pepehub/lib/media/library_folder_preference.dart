import '../data/repository.dart';

/// One default folder per shelf. Names may change; the connected root key is stable.
class LibraryFolderPreference {
  final Repository repository;
  final bool reading;
  const LibraryFolderPreference(this.repository, {required this.reading});

  String get key => '${reading ? 'reading' : 'audio'}-default-root';
  String get _prefix => '${reading ? 'reading' : 'audio'}-library-root:';

  Future<String?> load() async {
    final root = await repository.meta(key);
    if (root == null) return null;
    if (!root.startsWith(_prefix) || await repository.meta(root) == null) {
      await clear();
      return null;
    }
    return root;
  }

  Future<void> set(String? root) async {
    if (root == null) return clear();
    if (!root.startsWith(_prefix) || await repository.meta(root) == null) {
      throw StateError('Папка больше не подключена к этой библиотеке');
    }
    await repository.setMeta(key, root);
  }

  Future<void> clear() =>
      repository.db.customStatement('DELETE FROM metadata WHERE key=?', [key]);

  /// Called in the root operation's transaction so relocation/removal stays atomic.
  Future<void> replace(String from, String? to) async {
    if (to == null) {
      await repository.db.customStatement(
        'DELETE FROM metadata WHERE key=? AND value=?',
        [key, from],
      );
    } else {
      await repository.db.customStatement(
        'UPDATE metadata SET value=? WHERE key=? AND value=?',
        [to, key, from],
      );
    }
  }
}
