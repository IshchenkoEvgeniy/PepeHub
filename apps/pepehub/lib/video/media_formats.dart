const musicExtensions = [
  'mp3',
  'm4a',
  'm4b',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'wma',
  'aiff',
  'aif',
];

/// Works with local paths, escaped SAF document names and direct URLs.
/// Query strings are excluded: an extension in a signed token is not a format.
bool isMusicSource(String source) {
  final normalized = source.replaceAll('\\', '/');
  final isUri = RegExp(
    r'^(?:https?|content|file):',
    caseSensitive: false,
  ).hasMatch(normalized);
  final path = isUri
      ? (Uri.tryParse(normalized)?.path ?? normalized)
      : normalized;
  final name = path.split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot >= 0 && musicExtensions.contains(name.substring(dot + 1));
}
