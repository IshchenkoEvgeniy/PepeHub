import '../media/asset_store.dart';

/// Local files of the books on the reading shelf, grouped by book.
class ReadingShelfSources {
  final Map<String, List<LocalAsset>> byBook = {};
  ReadingShelfSources(Iterable<LocalAsset> assets) {
    for (final asset in assets) {
      (byBook[asset.bookId] ??= []).add(asset);
    }
  }
  LocalAsset? first(String id) => byBook[id]?.firstOrNull;
}
