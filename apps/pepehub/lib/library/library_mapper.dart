import '../data/repository.dart';
import 'models.dart';
import 'metadata_values.dart';

/// Property names always come from the plugin snapshot and its configured aliases.
class LibraryMapper {
  static ObsidianLibraryItem fromBook(
    LibraryRecord book,
    Map<String, dynamic> snapshot,
    Map<String, dynamic> details,
    String id,
  ) {
    final fields = [
      for (final value in snapshot['fields'] as List)
        LibraryField.fromJson(Map<String, dynamic>.from(value as Map)),
    ];
    final values = {for (final f in fields) f.key: null as dynamic};
    final audio = book.payload?['format'] == 'audio';
    final collections = (snapshot['collections'] as List).cast<Map>();
    final collection =
        collections
            .where((c) => c['mediaType'] == (audio ? 'audiobook' : 'book'))
            .firstOrNull ??
        collections.where((c) => c['id'] == 'book').firstOrNull;
    if (collection == null) {
      throw StateError('В Obsidian нет подходящей включённой коллекции.');
    }
    void set(String field, dynamic value) {
      final key = fields.where((f) => f.field == field).firstOrNull?.key;
      if (key != null) values[key] = value;
    }

    set('title', details['title'] ?? book.title);
    set('author', details['authors'] ?? book.payload?['authors'] ?? []);
    set('genre', details['genres']);
    set('series', details['series']);
    set('seriesIndex', details['seriesNumber'] ?? details['seriesIndex']);
    set('format', audio ? 'Audiobook' : 'E-book');
    set('libraryType', collection['id']);
    final percent =
        details['unit'] == 'characters' &&
        (collection['progressUnits'] as List? ?? []).contains('percent') &&
        (details['total'] as num? ?? 0) > 0;
    set(
      'unit',
      percent ? 'percent' : details['unit'] ?? (audio ? 'minutes' : 'pages'),
    );
    set('status', exportLibraryStatus(details['status'], collection));
    set('rating', details['rating']);
    set('startDate', details['startedAt'] ?? details['startDate']);
    set(
      'endDate',
      details['finishedAt'] ?? details['endDate'] ?? details['finishDate'],
    );
    set('readingTime', details['readingTime']);
    if (details['readingTime'] != null) {
      values['pepehub_time_from_journal'] = true;
    }
    set(
      'total',
      audio
          ? details['durationMinutes']
          : percent
          ? 100
          : details['total'] ?? details['pdfPages'] ?? details['pages'],
    );
    set(
      'progress',
      audio
          ? details['listenedMinutes']
          : percent
          ? (((details['progress'] as num? ?? 0) / (details['total'] as num)) *
                        10000)
                    .round() /
                100
          : details['progress'] ?? details['readPages'],
    );
    // Retain descriptive metadata; local file/cover paths and content are never exported.
    for (final key in [
      'description',
      'language',
      'isbn',
      'publisher',
      'year',
      'tags',
      'notes',
      'favorite',
      'publicationDate',
      'sourceLanguage',
      'publicationCity',
      'identifiers',
      'contributors',
      'rights',
      'subject',
      'keywords',
      'createdAt',
      'modifiedAt',
      'embeddedMetadata',
      'narrator',
    ]) {
      if (details.containsKey(key)) values[key] = details[key];
    }
    if (details['unit'] == 'characters') {
      values['pepehub_text_length'] = details['total'];
      values['pepehub_text_position'] = details['progress'];
    }
    final cover = details['cover'];
    if (cover is String &&
        (Uri.tryParse(cover)?.scheme == 'https' ||
            cover.startsWith('pepehub-cover:'))) {
      set('cover', cover);
    }
    return ObsidianLibraryItem(
      id: id,
      path: '',
      collectionId: collection['id'] as String,
      mediaType: audio ? 'audiobook' : 'book',
      values: values,
      fields: fields,
    );
  }
}
