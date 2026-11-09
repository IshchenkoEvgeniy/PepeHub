import 'models.dart';
import 'metadata_values.dart';
import 'library_dates.dart';

/// The app owns this schema. Connector aliases never become local field names.
const personalLibraryNamespace = 'personal';
const personalLibraryKey = 'library-catalog-v1';
const personalLibraryFields = <LibraryField>[
  LibraryField('title', 'title', 'text'),
  LibraryField('author', 'author', 'list'),
  LibraryField('genre', 'genre', 'list'),
  LibraryField('series', 'series', 'text'),
  LibraryField('seriesIndex', 'seriesIndex', 'number'),
  LibraryField('status', 'status', 'text'),
  LibraryField('total', 'total', 'number'),
  LibraryField('progress', 'progress', 'number'),
  LibraryField('rating', 'rating', 'number'),
  LibraryField('cover', 'cover', 'text'),
  LibraryField('format', 'format', 'text'),
  LibraryField('libraryType', 'libraryType', 'text'),
  LibraryField('startDate', 'startDate', 'date'),
  LibraryField('endDate', 'endDate', 'date'),
  LibraryField('unit', 'unit', 'text'),
  LibraryField('readingTime', 'readingTime', 'text'),
  LibraryField('rereadCount', 'rereadCount', 'number'),
  LibraryField('notes', 'notes', 'text'),
];

Map<String, dynamic> get personalLibrarySchema => {
  'version': 1,
  'ready': true,
  'fields': personalLibraryFields.map((f) => f.toJson()).toList(),
  'collections': [
    for (final type in ['book', 'audiobook'])
      {
        'id': type,
        'mediaType': type,
        'statuses': {
          'paused': 'paused',
          'abandoned': 'abandoned',
          'finished': 'finished',
        },
        'progressUnits': ['pages', 'minutes', 'hours', 'percent', 'characters'],
      },
  ],
};

LibraryItem personalLibraryItem(
  String id,
  String mediaType,
  Map<String, dynamic> values, {
  int? modifiedAt,
}) => LibraryItem(
  id: id,
  path: '',
  collectionId: mediaType,
  mediaType: mediaType,
  fields: personalLibraryFields,
  modifiedAt: modifiedAt ?? DateTime.now().millisecondsSinceEpoch,
  values: {
    for (final field in personalLibraryFields) field.key: null,
    ...values,
    'libraryType': mediaType,
  },
);

Map<String, dynamic> personalValues(
  LibraryItem remote, {
  Map? collection,
}) {
  final aliases = {for (final f in remote.fields) f.key: f.field};
  final result = {
    for (final entry in remote.values.entries)
      aliases[entry.key] ?? entry.key: entry.value,
  };
  final statuses = collection?['statuses'] as Map? ?? {};
  final status = result['status'];
  result['status'] =
      statuses.entries.where((e) => e.value == status).firstOrNull?.key ??
      canonicalLibraryStatus(status);
  result['libraryType'] = remote.mediaType;
  final hash = remote.coverAsset?['hash'];
  if (hash is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    result['pepehub_cover_asset'] = remote.coverAsset;
    final cover = '${result['cover'] ?? ''}';
    if (!cover.startsWith('https://') && !cover.startsWith('pepehub-cover:')) {
      result['cover'] = 'pepehub-cover:$hash';
    }
  }
  return result;
}

bool isLibraryDeleted(LibraryItem item) =>
    item.values['pepehub_deleted_at'] != null;

bool isFinishedLibraryItem(LibraryItem item) =>
    canonicalLibraryStatus(item.value('status')) == 'finished';

DateTime? libraryCompletionDate(LibraryItem item) =>
    libraryDate(item.value('endDate'));

DateTime? libraryStartDate(LibraryItem item) =>
    libraryDate(item.value('startDate'));
