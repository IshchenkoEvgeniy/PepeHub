import '../../data/database.dart';

/// A remote checkpoint never seeks an open reader or a loaded player.
class AppSyncUsage {
  static final _databases = Expando<Map<String, int>>();
  static void Function() hold(AppDatabase db, String target) {
    final entries = _databases[db] ??= {};
    entries[target] = (entries[target] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      if ((entries[target] ?? 1) <= 1) {
        entries.remove(target);
      } else {
        entries[target] = entries[target]! - 1;
      }
    };
  }

  static bool protected(AppDatabase db, String target) =>
      (_databases[db]?[target] ?? 0) > 0;
}
