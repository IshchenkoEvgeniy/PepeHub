import 'dart:convert';

class LibraryField {
  final String key, field, kind;
  const LibraryField(this.key, this.field, this.kind);
  factory LibraryField.fromJson(Map<String, dynamic> json) => LibraryField(
    json['key'] as String,
    json['field'] as String,
    json['kind'] as String,
  );
  Map<String, dynamic> toJson() => {'key': key, 'field': field, 'kind': kind};
}

class ObsidianLibraryItem {
  final String id, path, collectionId, mediaType;
  final int modifiedAt;
  final Map<String, dynamic> values;
  final List<LibraryField> fields;
  final Map<String, dynamic>? coverAsset;
  const ObsidianLibraryItem({
    required this.id,
    required this.path,
    required this.collectionId,
    required this.mediaType,
    required this.values,
    required this.fields,
    this.modifiedAt = 0,
    this.coverAsset,
  });
  factory ObsidianLibraryItem.fromJson(Map<String, dynamic> json) =>
      ObsidianLibraryItem(
        coverAsset: json['coverAsset'] is Map
            ? Map<String, dynamic>.from(json['coverAsset'] as Map)
            : null,
        id: json['id'] as String,
        path: json['path'] as String,
        collectionId: json['collectionId'] as String,
        mediaType: json['mediaType'] as String,
        modifiedAt: (json['modifiedAt'] as num?)?.toInt() ?? 0,
        values: {
          for (final field in json['fields'] as List)
            (field as Map)['key'] as String: null,
          ...Map<String, dynamic>.from(json['values'] as Map),
        },
        fields: [
          for (final field in json['fields'] as List)
            LibraryField.fromJson(Map<String, dynamic>.from(field as Map)),
        ],
      );
  dynamic value(String field) =>
      values[fields.where((f) => f.field == field).firstOrNull?.key];
  String get title => '${value('title') ?? ''}'.trim().isEmpty
      ? 'Без названия'
      : '${value('title')}';
  String get authors {
    final v = value('author');
    return v is List ? v.join(', ') : '${v ?? ''}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'collectionId': collectionId,
    'mediaType': mediaType,
    'modifiedAt': modifiedAt,
    if (coverAsset != null) 'coverAsset': coverAsset,
    'values': values,
    'fields': fields.map((f) => f.toJson()).toList(),
  };
  ObsidianLibraryItem withValues(Map<String, dynamic> next) =>
      ObsidianLibraryItem(
        id: id,
        path: path,
        collectionId: collectionId,
        mediaType: mediaType,
        modifiedAt: modifiedAt,
        coverAsset: coverAsset,
        values: next,
        fields: fields,
      );
}

class LibraryEntry {
  final ObsidianLibraryItem item;
  final String state;
  final String? sourceBookId, message;
  final Map<String, dynamic>? operation;
  final ObsidianLibraryItem? remote;
  const LibraryEntry(
    this.item, {
    this.state = 'synced',
    this.sourceBookId,
    this.message,
    this.operation,
    this.remote,
  });
  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    ObsidianLibraryItem.fromJson(
      Map<String, dynamic>.from(json['item'] as Map),
    ),
    state: json['state'] as String? ?? 'synced',
    sourceBookId: json['sourceBookId'] as String?,
    message: json['message'] as String?,
    operation: json['operation'] == null
        ? null
        : Map<String, dynamic>.from(json['operation'] as Map),
    remote: json['remote'] == null
        ? null
        : ObsidianLibraryItem.fromJson(
            Map<String, dynamic>.from(json['remote'] as Map),
          ),
  );
  Map<String, dynamic> toJson() => {
    'item': item.toJson(),
    'state': state,
    'sourceBookId': sourceBookId,
    'message': message,
    'operation': operation,
    'remote': remote?.toJson(),
  };
  bool get pending => state == 'pending';
}

bool sameMetadataValue(dynamic a, dynamic b) {
  if (a == b) return true;
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => sameMetadataValue(a[i], b[i]),
        ).every((v) => v);
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && sameMetadataValue(a[key], b[key]),
        );
  }
  return false;
}

String metadataText(dynamic value) => value == null
    ? ''
    : value is String
    ? value
    : jsonEncode(value);
