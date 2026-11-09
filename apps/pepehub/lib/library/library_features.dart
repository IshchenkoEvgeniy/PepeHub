import 'metadata_values.dart';
import 'models.dart';
import 'personal_library.dart';

String seriesTextKey(Object? value) =>
    '${value ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String librarySeriesKey(LibraryItem item) {
  final name = seriesTextKey(item.value('series'));
  if (name.isEmpty) return 'book:${item.id}';
  final id = item.values['pepehub_series_id'];
  return id is String && id.isNotEmpty ? 'series-id:$id' : 'series:$name';
}

/// Reconnect name-only cards only when the saved catalog identifies one cycle.
/// Distinct explicitly created cycles with the same name remain separate.
Map<String, String> missingLibrarySeriesLinks(Iterable<LibraryEntry> entries) {
  final ids = <String, Set<String>>{};
  final unbound = <LibraryEntry>[];
  for (final entry in entries) {
    if (!isSeriesCatalogItem(entry.item) || isLibraryDeleted(entry.item)) {
      continue;
    }
    final name = seriesTextKey(entry.item.value('series'));
    if (name.isEmpty) continue;
    final id = entry.item.values['pepehub_series_id'];
    if (id is String && id.isNotEmpty) {
      (ids[name] ??= {}).add(id);
    } else {
      unbound.add(entry);
    }
  }
  return {
    for (final entry in unbound)
      if (ids[seriesTextKey(entry.item.value('series'))]?.length == 1)
        entry.item.id: ids[seriesTextKey(entry.item.value('series'))]!.single,
  };
}

/// Offer matching descriptive values, never another volume's reading result.
Map<String, dynamic> commonLibrarySeriesMetadata(
  LibrarySeriesGroup group,
  LibraryItem target,
) {
  final result = <String, dynamic>{};
  for (final field in [
    'author',
    'narrator',
    'genre',
    'language',
    'publisher',
    'tags',
  ]) {
    if (field == 'narrator' && target.mediaType != 'audiobook') continue;
    final tokens = ['author', 'narrator', 'genre', 'tags'].contains(field);
    Object? comparison;
    Object? proposal;
    var different = false;
    for (final entry in group.entries) {
      if (entry.item.id == target.id ||
          field == 'narrator' && entry.item.mediaType != 'audiobook') {
        continue;
      }
      final raw = entry.item.value(field) ?? entry.item.values[field];
      final value = tokens ? metadataStrings(raw) : '${raw ?? ''}'.trim();
      if (value is List && value.isEmpty || value == '') continue;
      final normalized = tokens
          ? ((value as List<String>).map(seriesTextKey).toList()..sort())
          : seriesTextKey(value);
      if (comparison != null && !sameMetadataValue(comparison, normalized)) {
        different = true;
        break;
      }
      comparison = normalized;
      proposal ??= value;
    }
    if (!different && proposal != null) result[field] = proposal;
  }
  return result;
}

const libraryStatusesLocal = {
  'paused': 'Отложена',
  'abandoned': 'Брошена',
  'finished': 'Завершённая',
};

/// Unstarted volumes describe a series' composition, outside the archive.
bool isUnreadSeriesItem(LibraryItem item) =>
    libraryStatus(item) == 'unread' &&
    '${item.value('series') ?? ''}'.trim().isNotEmpty &&
    item.values['pepehub_auto_discovered'] != true &&
    item.values['pepehub_source_only'] != true &&
    item.values['pepehub_recommendation_only'] != true;

bool isSeriesCatalogItem(LibraryItem item) =>
    isLibraryArchiveItem(item) || isUnreadSeriesItem(item);

Map<String, String> seriesVolumeStatuses(String mediaType) => {
  ...libraryStatusesLocal,
  'unread': switch (mediaType) {
    'audiobook' => 'Не прослушана',
    'book' => 'Не прочитана',
    _ => 'Не прочитана / не прослушана',
  },
};

Map<String, String> libraryItemStatuses(LibraryItem item) =>
    '${item.value('series') ?? ''}'.trim().isEmpty
    ? libraryStatusesLocal
    : seriesVolumeStatuses(item.mediaType);

/// The personal archive contains outcomes, never a file shelf or reading queue.
bool isLibraryArchiveItem(LibraryItem item) =>
    libraryStatusesLocal.containsKey(libraryStatus(item)) &&
    item.values['pepehub_auto_discovered'] != true &&
    item.values['pepehub_source_only'] != true &&
    item.values['pepehub_recommendation_only'] != true;

String libraryStatus(LibraryItem item) =>
    canonicalLibraryStatus(item.value('status'));

DateTime? libraryAddedAt(LibraryItem item) =>
    DateTime.tryParse('${item.values['pepehub_added_at'] ?? ''}');

int libraryRereads(LibraryItem item) {
  final value = item.value('rereadCount') ?? item.values['rereadCount'];
  return value is num && value.isFinite ? value.toInt().clamp(0, 99999) : 0;
}

List<String> libraryCollections(LibraryItem item) =>
    metadataStrings(item.values['pepehub_collections']);

num? libraryRating(LibraryItem item) {
  final value = num.tryParse('${item.value('rating')}'.replaceAll(',', '.'));
  return value != null && value.isFinite && value >= 0 ? value : null;
}

String libraryRatingLabel(LibraryItem item) {
  final rating = libraryRating(item);
  if (rating == null) return '—';
  return '★ ${rating == rating.roundToDouble() ? rating.toInt() : rating}';
}

class LibrarySeriesGroup {
  final String name, key;
  final List<LibraryEntry> entries;
  LibrarySeriesGroup(this.name, this.key, this.entries);
  bool get isSeries =>
      name.isNotEmpty &&
      (entries.length > 1 ||
          key.startsWith('series-id:') ||
          entries.any((e) => isUnreadSeriesItem(e.item)));

  num get listenedMinutes {
    num sum = 0;
    for (final entry in entries) {
      final item = entry.item;
      if (item.mediaType != 'audiobook' || isUnreadSeriesItem(item)) continue;
      final unit = '${item.value('unit') ?? ''}'.trim().toLowerCase();
      if (!['', 'minutes', 'minute', 'мин', 'минуты', 'hours'].contains(unit)) {
        continue;
      }
      num? amount(Object? value) {
        final n = num.tryParse('$value');
        return n != null && n.isFinite && n >= 0 ? n : null;
      }

      final total = amount(item.value('total'));
      var progress =
          amount(item.value('progress')) ??
          (isFinishedLibraryItem(item) ? total : null);
      if (progress == null) continue;
      if (total != null && total > 0 && progress > total) progress = total;
      sum += progress * (unit == 'hours' ? 60 : 1);
    }
    return sum;
  }
}

/// Preserve the current shelf order between groups. Within a series, numbered
/// volumes precede unnumbered ones, irrespective of the shelf's sort direction.
List<LibrarySeriesGroup> groupLibrarySeries(List<LibraryEntry> sorted) {
  final groups = <String, LibrarySeriesGroup>{};
  for (final entry in sorted) {
    final name = '${entry.item.value('series') ?? ''}'.trim();
    final key = librarySeriesKey(entry.item);
    (groups.putIfAbsent(key, () => LibrarySeriesGroup(name, key, [])).entries)
        .add(entry);
  }
  num? index(LibraryEntry entry) {
    final n = num.tryParse(
      '${entry.item.value('seriesIndex')}'.replaceAll(',', '.'),
    );
    return n?.isFinite == true && n! >= 0 ? n : null;
  }

  for (final group in groups.values.where((g) => g.isSeries)) {
    group.entries.sort((a, b) {
      final x = index(a), y = index(b);
      final order = x == null || y == null
          ? x == y
                ? 0
                : x == null
                ? 1
                : -1
          : x.compareTo(y);
      if (order != 0) return order;
      final title = a.item.title.toLowerCase().compareTo(
        b.item.title.toLowerCase(),
      );
      return title != 0 ? title : a.item.id.compareTo(b.item.id);
    });
  }
  return groups.values.toList();
}

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
  if (['added', 'started', 'completed'].contains(sort)) {
    result = switch (sort) {
      'added' => date(libraryAddedAt(left), libraryAddedAt(right)),
      'started' => date(libraryStartDate(left), libraryStartDate(right)),
      _ => date(libraryCompletionDate(left), libraryCompletionDate(right)),
    };
  } else {
    result = switch (sort) {
      'author' => left.authors.toLowerCase().compareTo(
        right.authors.toLowerCase(),
      ),
      'series' => '${left.value('series') ?? ''}'.toLowerCase().compareTo(
        '${right.value('series') ?? ''}'.toLowerCase(),
      ),
      'rating' => (libraryRating(left) ?? -1).compareTo(
        libraryRating(right) ?? -1,
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
