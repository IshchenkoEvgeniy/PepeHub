class VideoAnnotation {
  final String id, lessonId, mediaVersion, title, body;
  final int startMs, revision;
  final int? endMs;
  final DateTime createdAt, updatedAt;
  const VideoAnnotation({
    required this.id,
    required this.lessonId,
    required this.mediaVersion,
    required this.title,
    this.body = '',
    required this.startMs,
    this.endMs,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
  });

  factory VideoAnnotation.fromJson(
    String id,
    int revision,
    Map<String, dynamic> data,
  ) => VideoAnnotation(
    id: id,
    revision: revision,
    lessonId: data['lessonId'] as String,
    mediaVersion: data['mediaVersion'] as String,
    title: data['title'] as String,
    body: data['body'] as String? ?? '',
    startMs: data['startMs'] as int,
    endMs: data['endMs'] as int?,
    createdAt: DateTime.parse(data['createdAt'] as String),
    updatedAt: DateTime.parse(data['updatedAt'] as String),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'lessonId': lessonId,
    'mediaVersion': mediaVersion,
    'title': title,
    'body': body,
    'startMs': startMs,
    'endMs': endMs,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// A revision-bound undo token. An older undo cannot replace a later edit.
class VideoAnnotationDeletion {
  final VideoAnnotation annotation;
  final int revision;
  const VideoAnnotationDeletion(this.annotation, this.revision);
}
