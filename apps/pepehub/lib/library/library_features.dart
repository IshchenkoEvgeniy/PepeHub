import 'metadata_values.dart';
import 'models.dart';
import 'personal_library.dart';

const libraryStatusesLocal = {
  'paused': 'Отложена',
  'abandoned': 'Брошена',
  'finished': 'Завершённая',
};

/// The personal archive contains outcomes, never a file shelf or reading queue.
bool isLibraryArchiveItem(ObsidianLibraryItem item) =>
    libraryStatusesLocal.containsKey(libraryStatus(item)) &&
    item.values['pepehub_auto_discovered'] != true &&
    item.values['pepehub_source_only'] != true &&
    item.values['pepehub_recommendation_only'] != true;

String libraryStatus(ObsidianLibraryItem item) =>
    canonicalLibraryStatus(item.value('status'));

DateTime? libraryAddedAt(ObsidianLibraryItem item) =>
    DateTime.tryParse('${item.values['pepehub_added_at'] ?? ''}');

int libraryRereads(ObsidianLibraryItem item) {
  final value = item.value('rereadCount') ?? item.values['rereadCount'];
  return value is num && value.isFinite ? value.toInt().clamp(0, 99999) : 0;
}

List<String> libraryCollections(ObsidianLibraryItem item) =>
    metadataStrings(item.values['pepehub_collections']);

int compareLibraryEntries(
  LibraryEntry a,
  LibraryEntry b,
  String sort, {
  bool descending = false,
}) {
  final left = a.item, right = b.item;
  int date(DateTime? x, DateTime? y) {
    // Unknown dates always follow known dates, in either direction.
    if (x == null || y == null) {
      return x == y
          ? 0
          : x == null
          ? 1
          : -1;
    }
    final result = x.compareTo(y);
    return descending ? -result : result;
  }

  num? number(dynamic value) {
    final n = value is num ? value : num.tryParse('$value');
    return n?.isFinite == true ? n : null;
  }

  int result;
  if (sort == 'added' || sort == 'completed') {
    result = sort == 'added'
        ? date(libraryAddedAt(left), libraryAddedAt(right))
        : date(libraryCompletionDate(left), libraryCompletionDate(right));
  } else {
    result = switch (sort) {
      'author' => left.authors.toLowerCase().compareTo(
        right.authors.toLowerCase(),
      ),
      'series' => '${left.value('series') ?? ''}'.toLowerCase().compareTo(
        '${right.value('series') ?? ''}'.toLowerCase(),
      ),
      'rating' => (number(left.value('rating')) ?? -1).compareTo(
        number(right.value('rating')) ?? -1,
      ),
      'recent' => left.modifiedAt.compareTo(right.modifiedAt),
      'progress' =>
        ((number(left.value('progress')) ?? 0) /
                ((number(left.value('total')) ?? 0) > 0
                    ? number(left.value('total'))!
                    : 1))
            .compareTo(
              (number(right.value('progress')) ?? 0) /
                  ((number(right.value('total')) ?? 0) > 0
                      ? number(right.value('total'))!
                      : 1),
            ),
      _ => left.title.toLowerCase().compareTo(right.title.toLowerCase()),
    };
    if (descending) result = -result;
  }
  return result != 0
      ? result
      : left.title.toLowerCase().compareTo(right.title.toLowerCase());
}
