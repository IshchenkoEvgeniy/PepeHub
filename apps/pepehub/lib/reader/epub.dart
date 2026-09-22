import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'book_markup.dart';
export 'book_markup.dart';

class EpubChapter {
  final String path, title;
  final List<String> paragraphs;
  final List<BookFootnote> footnotes;
  final List<BookIllustration> illustrations;
  final List<BookMarkup> markup;
  const EpubChapter(
    this.path,
    this.title,
    this.paragraphs, {
    this.footnotes = const [],
    this.illustrations = const [],
    this.markup = const [],
  });
}

class BookFootnote {
  final String label, text;
  final int start, end;
  const BookFootnote(this.label, this.text, this.start, this.end);
}

class BookIllustration {
  final String label;
  final Uint8List bytes;
  final int offset;
  const BookIllustration(this.label, this.bytes, {this.offset = 0});
}

/// Resolve only resources inside the archive, never filesystem/network paths.
String? bookResourcePath(String base, String href) {
  final uri = Uri.tryParse(href);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.path.startsWith('/')) {
    return null;
  }
  final decoded = Uri.decodeComponent(uri.path);
  if (decoded.contains('\\') || decoded.contains('\u0000')) return null;
  final result = decoded.isEmpty
      ? base
      : p.posix.normalize(p.posix.join(p.posix.dirname(base), decoded));
  return result.startsWith('../') || result.startsWith('/') ? null : result;
}

class EpubBook {
  final String title;
  final List<String> authors;
  final List<EpubChapter> chapters;
  final String? series, seriesNumber, description;
  final Uint8List? cover;
  const EpubBook(
    this.title,
    this.authors,
    this.chapters, {
    this.series,
    this.description,
    this.seriesNumber,
    this.cover,
  });
}

Future<EpubBook> loadEpub(String path) => Isolate.run(() {
  final file = File(path);
  if (file.lengthSync() > 64 * 1024 * 1024) {
    throw const FormatException('EPUB превышает 64 МБ');
  }
  return parseEpub(file.readAsBytesSync());
});

class _LimitedBytes implements Sink<List<int>> {
  final int limit;
  final builder = BytesBuilder(copy: false);
  _LimitedBytes(this.limit);
  @override
  void add(List<int> data) {
    if (builder.length + data.length > limit) {
      throw const FormatException('Слишком большой раздел EPUB');
    }
    builder.add(data);
  }

  @override
  void close() {}
}

/// EPUB text with bounded local resources. Never extracts archive paths or loads remote resources.
EpubBook parseEpub(Uint8List bytes, {bool legacyProjection = false}) {
  if (bytes.length > 64 * 1024 * 1024) {
    throw const FormatException('EPUB превышает 64 МБ');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 5000) {
    throw const FormatException('Некорректный или слишком большой архив EPUB');
  }
  final files = <String, ZipFileHeader>{};
  var declared = 0;
  for (final entry in directory.fileHeaders) {
    final name = entry.filename;
    if (name.contains('\\') ||
        name.startsWith('/') ||
        name.split('/').contains('..') ||
        files.containsKey(name) ||
        (entry.generalPurposeBitFlag & 1) != 0 ||
        ![0, 8].contains(entry.compressionMethod)) {
      throw const FormatException('Неподдерживаемая структура EPUB');
    }
    declared += entry.uncompressedSize;
    if (declared > 256 * 1024 * 1024) {
      throw const FormatException('Распакованный EPUB превышает 256 МБ');
    }
    files[name] = entry;
  }
  var decoded = 0;
  Uint8List readBytes(String name) {
    final entry = files[name];
    if (entry == null || entry.file == null) {
      throw FormatException('В EPUB отсутствует $name');
    }
    const limit = 4 * 1024 * 1024;
    if (entry.uncompressedSize > limit ||
        decoded + entry.uncompressedSize > 32 * 1024 * 1024) {
      throw const FormatException('Раздел EPUB превышает 4 МБ');
    }
    final output = _LimitedBytes(limit);
    final raw = InputMemoryStream(entry.file!.getRawContent());
    if (entry.compressionMethod == 8) {
      final decoder = ZLibCodec(raw: true).decoder
          .startChunkedConversion(output);
      while (!raw.isEOS) {
        decoder.add(raw.readBytes(raw.length.clamp(0, 8192)).toUint8List());
      }
      decoder.close();
    } else {
      output.add(raw.toUint8List());
    }
    final content = output.builder.takeBytes();
    decoded += content.length;
    if (decoded > 32 * 1024 * 1024 ||
        content.length != entry.uncompressedSize ||
        getCrc32(content) != entry.crc32) {
      throw const FormatException(
        'EPUB повреждён или содержит слишком много текста',
      );
    }
    return content;
  }

  String read(String name) => utf8.decode(readBytes(name));

  XmlDocument xml(String name) {
    final text = read(name);
    if (text.contains('<!ENTITY')) {
      throw const FormatException('XML entities не поддерживаются');
    }
    return XmlDocument.parse(text);
  }

  if (read('mimetype').trim() != 'application/epub+zip') {
    throw const FormatException('Это не EPUB');
  }
  if (files.containsKey('META-INF/encryption.xml')) {
    throw const FormatException('Зашифрованные EPUB пока не поддерживаются');
  }
  final container = xml('META-INF/container.xml');
  final root = container.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'rootfile')
      .firstOrNull;
  final packagePath = root?.getAttribute('full-path');
  if (packagePath == null) throw const FormatException('Не найден пакет EPUB');
  final package = xml(packagePath);
  final elements = package.descendants.whereType<XmlElement>();
  String resolve(String href) {
    final uri = Uri.parse(href);
    if (uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) {
      throw const FormatException('Внешняя ссылка в порядке чтения EPUB');
    }
    final resolved = p.posix.normalize(
      p.posix.join(p.posix.dirname(packagePath), Uri.decodeComponent(uri.path)),
    );
    if (resolved.startsWith('../') || resolved.contains('\\')) {
      throw const FormatException('Некорректный путь EPUB');
    }
    return resolved;
  }

  final manifest = <String, XmlElement>{
    for (final e in elements.where((e) => e.name.local == 'item'))
      if (e.getAttribute('id') != null) e.getAttribute('id')!: e,
  };
  final chapters = <EpubChapter>[];
  final pendingImages = <BookIllustration>[];
  final resourceCache = <String, Uint8List>{};
  var resourceBytes = 0;
  Uint8List? artwork(String path) {
    if (resourceCache.containsKey(path)) return resourceCache[path];
    if (resourceBytes >= 12 * 1024 * 1024) return null;
    try {
      final bytes = readBytes(path);
      if (resourceBytes + bytes.length > 12 * 1024 * 1024) return null;
      resourceBytes += bytes.length;
      return resourceCache[path] = bytes;
    } on FormatException {
      return null;
    }
  }

  for (final ref in elements.where(
    (e) => e.name.local == 'itemref' && e.getAttribute('linear') != 'no',
  )) {
    final item = manifest[ref.getAttribute('idref')];
    if (item == null ||
        item.getAttribute('media-type') != 'application/xhtml+xml') {
      throw const FormatException(
        'Поддерживается текстовый EPUB с XHTML-главами',
      );
    }
    final path = resolve(item.getAttribute('href') ?? '');
    final document = html.parse(read(path));
    if (legacyProjection) {
      for (final node in document.querySelectorAll('svg,nav')) {
        node.remove();
      }
    }
    final styles = document
        .querySelectorAll('style')
        .map((e) => e.text)
        .toList();
    for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
      final target = bookResourcePath(path, link.attributes['href'] ?? '');
      if (target == null || !files.containsKey(target)) continue;
      try {
        styles.add(read(target));
      } on FormatException {
        /* Optional stylesheet. */
      }
    }
    applyBookCss(document, styles);
    for (final e in document.querySelectorAll('script,style,iframe,object')) {
      e.remove();
    }
    final body = document.body;
    final paragraphs = <String>[];
    final links = <({String href, String label, int start, int end})>[];
    final illustrations = <BookIllustration>[];
    final imagePaths = <String>{};
    var buffer = StringBuffer();
    var flushedLength = 0;
    int position() =>
        flushedLength +
        buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trimLeft().length;
    void flush() {
      final text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) {
        paragraphs.add(text);
        flushedLength += text.length + 2;
      }
      buffer = StringBuffer();
    }

    void visit(dom.Node node, [int depth = 0]) {
      if (depth > 256) {
        throw const FormatException('Слишком глубокая разметка EPUB');
      }
      if (node is dom.Text) {
        buffer.write(node.data);
        return;
      }
      final tag = node is dom.Element ? node.localName : null;
      if (!legacyProjection && node is dom.Element && tag == 'pre') {
        flush();
        final code = node.text.trim();
        if (code.isNotEmpty) {
          paragraphs.add(code);
          flushedLength += code.length + 2;
        }
        return;
      }
      if (node is dom.Element &&
          (tag == 'img' || tag == 'image') &&
          illustrations.length < 64) {
        final target = bookResourcePath(
          path,
          node.attributes['src'] ??
              node.attributes['href'] ??
              node.attributes['xlink:href'] ??
              '',
        );
        if (target != null && imagePaths.add(target)) {
          final bytes = artwork(target);
          if (bytes != null) {
            illustrations.add(
              BookIllustration(
                node.attributes['alt']?.trim().isNotEmpty == true
                    ? node.attributes['alt']!
                    : 'Иллюстрация ${illustrations.length + 1}',
                bytes,
                offset: position(),
              ),
            );
          }
        }
      }
      final block = const {
        'h1',
        'h2',
        'h3',
        'h4',
        'h5',
        'h6',
        'p',
        'li',
        'blockquote',
        'pre',
        'div',
        'section',
        'article',
        'tr',
        'br',
      }.contains(tag);
      if (block) flush();
      final linkStart = position();
      for (final child in node.nodes) {
        visit(child, depth + 1);
      }
      if (node is dom.Element && tag == 'a' && links.length < 256) {
        final href = node.attributes['href'] ?? '';
        final label = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (href.contains('#') && label.isNotEmpty) {
          links.add((
            href: href,
            label: label,
            start: linkStart,
            end: position(),
          ));
        }
      }
      if (tag == 'td' || tag == 'th') buffer.write(' ');
      if (block) flush();
    }

    if (body != null) visit(body);
    flush();
    final text = paragraphs.join('\n\n');
    final footnotes = <BookFootnote>[];
    final targets = <String, dom.Document>{path: document};
    for (final link in links) {
      final targetPath = bookResourcePath(path, link.href);
      if (targetPath == null) continue;
      try {
        final target = targets.putIfAbsent(
          targetPath,
          () => html.parse(read(targetPath)),
        );
        final id = Uri.decodeComponent(Uri.parse(link.href).fragment);
        final element = target.getElementById(id);
        if (element == null) continue;
        final type =
            element.attributes['epub:type'] ?? element.attributes['role'] ?? '';
        // Generic intra-book navigation is not a footnote.
        final source = document
            .querySelectorAll('a')
            .where((a) => a.attributes['href'] == link.href)
            .firstOrNull;
        final sourceType =
            '${source?.attributes['epub:type']} ${source?.attributes['role']}';
        if (!RegExp(r'footnote|endnote|noteref')
                .hasMatch('$type $sourceType') &&
            !RegExp(
              r'note|foot',
              caseSensitive: false,
            ).hasMatch('$targetPath#$id')) {
          continue;
        }
        final content = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final end = link.end.clamp(0, text.length);
        var start = link.start.clamp(0, end);
        while (start < end && text[start].trim().isEmpty) {
          start++;
        }
        if (content.isNotEmpty && content.length <= 32000 && start < end) {
          footnotes.add(BookFootnote(link.label, content, start, end));
        }
      } on FormatException {
        /* Optional unresolved note. */
      }
    }
    if (paragraphs.isNotEmpty) {
      final title = document.querySelector('h1,h2,title')?.text.trim();
      chapters.add(
        EpubChapter(
          path,
          title == null || title.isEmpty
              ? 'Глава ${chapters.length + 1}'
              : title,
          paragraphs,
          footnotes: footnotes,
          illustrations: [...pendingImages, ...illustrations],
          markup: htmlMarkup(body ?? document, text),
        ),
      );
      pendingImages.clear();
    } else {
      pendingImages.addAll(illustrations);
    }
  }
  if (pendingImages.isNotEmpty) {
    if (chapters.isEmpty) {
      chapters.add(
        EpubChapter('images', 'Иллюстрации', const [
          '',
        ], illustrations: pendingImages),
      );
    } else {
      final last = chapters.removeLast();
      chapters.add(
        EpubChapter(
          last.path,
          last.title,
          last.paragraphs,
          footnotes: last.footnotes,
          markup: last.markup,
          illustrations: [
            ...last.illustrations,
            for (final image in pendingImages)
              BookIllustration(
                image.label,
                image.bytes,
                offset: last.paragraphs.join('\n\n').length,
              ),
          ],
        ),
      );
    }
  }
  if (chapters.isEmpty) {
    throw const FormatException('В EPUB нет читаемого текста');
  }
  final title = elements
      .where((e) => e.name.local == 'title')
      .firstOrNull
      ?.innerText
      .trim();
  final metadata = elements.where((e) => e.name.local == 'meta').toList();
  final collection = metadata
      .where((e) => e.getAttribute('property') == 'belongs-to-collection')
      .firstOrNull;
  final series =
      metadata
          .where((e) => e.getAttribute('name') == 'calibre:series')
          .firstOrNull
          ?.getAttribute('content') ??
      collection?.innerText.trim();
  final number =
      metadata
          .where((e) => e.getAttribute('name') == 'calibre:series_index')
          .firstOrNull
          ?.getAttribute('content') ??
      metadata
          .where(
            (e) =>
                e.getAttribute('property') == 'group-position' &&
                e.getAttribute('refines') ==
                    '#${collection?.getAttribute('id')}',
          )
          .firstOrNull
          ?.innerText
          .trim();
  final coverId = metadata
      .where((e) => e.getAttribute('name') == 'cover')
      .firstOrNull
      ?.getAttribute('content');
  final coverItem =
      manifest.values
          .where(
            (e) => (e.getAttribute('properties') ?? '')
                .split(' ')
                .contains('cover-image'),
          )
          .firstOrNull ??
      manifest[coverId];
  Uint8List? cover;
  if (coverItem != null) {
    try {
      cover = readBytes(resolve(coverItem.getAttribute('href') ?? ''));
    } on FormatException {
      /* Optional artwork must not prevent reading. */
    }
  }
  return EpubBook(
    title == null || title.isEmpty ? 'Книга EPUB' : title,
    elements
        .where((e) => e.name.local == 'creator')
        .map((e) => e.innerText.trim())
        .where((s) => s.isNotEmpty)
        .take(30)
        .toList(),
    chapters,
    description: elements
        .where((e) => e.name.local == 'description')
        .firstOrNull
        ?.innerText
        .trim(),
    series: series,
    seriesNumber: number,
    cover: cover,
  );
}
