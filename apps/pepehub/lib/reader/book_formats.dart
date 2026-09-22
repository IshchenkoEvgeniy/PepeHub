import 'package:path/path.dart' as p;

const bookFormats = <String, String>{
  'epub': 'EPUB',
  'fb2': 'FB2',
  'txt': 'TXT',
  'md': 'Markdown',
  'html': 'HTML',
  'docx': 'DOCX',
  'pdf': 'PDF',
  'rtf': 'RTF',
};
const bookExtensions = [
  'epub',
  'fb2',
  'zip',
  'txt',
  'md',
  'markdown',
  'html',
  'htm',
  'xhtml',
  'docx',
  'pdf',
  'rtf',
];
const audioExtensions = [
  'mp3',
  'm4b',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'flac',
  'wav',
];

String bookFormat(String filename) {
  final name = filename.toLowerCase();
  if (name.endsWith('.fb2.zip')) return 'fb2';
  final extension = p.extension(name).replaceFirst('.', '');
  final format = switch (extension) {
    'markdown' => 'md',
    'zip' => 'fb2',
    'htm' || 'xhtml' => 'html',
    _ => extension,
  };
  if (!bookFormats.containsKey(format)) {
    throw const FormatException(
      'Этот формат пока не поддерживается. Доступны EPUB, FB2, FB2.ZIP, TXT, Markdown, HTML, DOCX, RTF и PDF.',
    );
  }
  return format;
}

String formatLabel(String format) => format == 'audio'
    ? 'Аудиокнига'
    : bookFormats[format] ?? format.toUpperCase();
