import '../data/repository.dart';
import 'models.dart';

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
    set('unit', audio ? 'minutes' : 'pages');
    set('status', details['status']);
    set('rating', details['rating']);
    set('startDate', details['startDate']);
    set('endDate', details['endDate'] ?? details['finishDate']);
    set(
      'total',
      audio
          ? details['durationMinutes']
          : details['pdfPages'] ?? details['pages'],
    );
    set('progress', audio ? details['listenedMinutes'] : details['readPages']);
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
    ]) {
      if (details.containsKey(key)) values[key] = details[key];
    }
    final cover = details['cover'];
    if (cover is String && Uri.tryParse(cover)?.scheme == 'https') {
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
