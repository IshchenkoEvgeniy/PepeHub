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

final _legacyNoteId = RegExp(
  r'^(?:n|fn|ftn|note|footnote|endnote)[_-]?[0-9]+$',
  caseSensitive: false,
);

String _epubFootnoteText(dom.Element anchor) {
  String normalized(dom.Element node) =>
      node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  bool explanation(String text) =>
      text.isNotEmpty &&
      !RegExp(r'^[\s0-9⁰¹²³⁴⁵⁶⁷⁸⁹\[\]().:†*↩←_-]+$').hasMatch(text);
  final id = anchor.id.isNotEmpty ? anchor.id : anchor.attributes['name'];
  bool containsNextNote(dom.Element node) =>
      [node, ...node.querySelectorAll('[id], [name]')].any((child) {
        final value = child.id.isNotEmpty ? child.id : child.attributes['name'];
        return value != null && value != id && _legacyNoteId.hasMatch(value);
      });

  var block = anchor;
  while (!explanation(normalized(block))) {
    final parent = block.parent;
    if (parent == null ||
        const {'body', 'html'}.contains(parent.localName) ||
        containsNextNote(parent)) {
      break;
    }
    block = parent;
  }
  final ownText = normalized(block);
  if (explanation(ownText)) return ownText;
  final parts = <String>[if (ownText.isNotEmpty) ownText];
  var length = ownText.length;
  // Older converters place a named anchor or numeric title before the note
  // paragraphs. Stop at the next note instead of including the whole file.
  for (
    var next = block.nextElementSibling;
    next != null;
    next = next.nextElementSibling
  ) {
    if (containsNextNote(next) ||
        RegExp(r'^h[1-6]$').hasMatch(next.localName ?? '')) {
      break;
    }
    final text = normalized(next);
    length += text.length;
    if (length > 32000) break;
    if (text.isNotEmpty) parts.add(text);
  }
  return parts.join('\n\n');
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
  final Map<String, dynamic> metadata;
  const EpubBook(
    this.title,
    this.authors,
    this.chapters, {
    this.series,
    this.description,
    this.seriesNumber,
    this.cover,
    this.metadata = const {},
  });
}

Future<EpubBook> loadEpub(String path) => Isolate.run(() {
  final file = File(path);
  if (file.lengthSync() > 64 * 1024 * 1024) {
    throw const FormatException('EPUB превышает 64 МБ');
  }
  return parseEpub(file.readAsBytesSync());
});

String? _cleanTitle(String? value) {
  final text = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text == null || text.isEmpty) return null;
  return text.length > 200 ? '${text.substring(0, 199)}…' : text;
}

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

  // A single invalid byte must not make the whole book unreadable.
  String read(String name) =>
      utf8.decode(readBytes(name), allowMalformed: true);

  XmlDocument xml(String name) {
    final text = read(name).replaceFirst(RegExp('^\uFEFF'), '');
    if (text.contains('<!ENTITY')) {
      throw const FormatException('XML entities не поддерживаются');
    }
    return XmlDocument.parse(text);
  }

  if (read('mimetype').trim() != 'application/epub+zip') {
    throw const FormatException('Это не EPUB');
  }
  if (files.containsKey('META-INF/encryption.xml')) {
    // Font obfuscation also uses encryption.xml and is common in DRM-free
    // books. Embedded fonts are never read, so only real DRM is refused.
    const fontObfuscation = {
      'http://www.idpf.org/2008/embedding',
      'http://ns.adobe.com/pdf/enc#RC',
    };
    var onlyFonts = false;
    try {
      final methods = [
        for (final data
            in xml('META-INF/encryption.xml').descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'EncryptedData'))
          data.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'EncryptionMethod')
              .firstOrNull
              ?.getAttribute('Algorithm'),
      ];
      onlyFonts = methods.isNotEmpty && methods.every(fontObfuscation.contains);
    } catch (_) {
      /* Unreadable encryption data is treated as DRM. */
    }
    if (!onlyFonts) {
      throw const FormatException('Зашифрованные EPUB пока не поддерживаются');
    }
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
  final bookTitle = _cleanTitle(
    elements.where((e) => e.name.local == 'title').firstOrNull?.innerText,
  );
  // Chapter names come from the book's own table of contents first. Many
  // EPUBs repeat the book title in every XHTML <title>.
  final tocTitles = <String, String>{};
  void addToc(String base, String href, String? label) {
    final target = bookResourcePath(base, href);
    final text = _cleanTitle(label);
    if (target == null || text == null) return;
    tocTitles.putIfAbsent(target, () => text);
  }

  try {
    final navItem = manifest.values
        .where(
          (e) => (e.getAttribute('properties') ?? '')
              .split(RegExp(r'\s+'))
              .contains('nav'),
        )
        .firstOrNull;
    if (navItem != null) {
      final navPath = resolve(navItem.getAttribute('href') ?? '');
      final navs = html.parse(read(navPath)).querySelectorAll('nav');
      final toc =
          navs
              .where(
                (n) => (n.attributes['epub:type'] ?? '')
                    .split(RegExp(r'\s+'))
                    .contains('toc'),
              )
              .firstOrNull ??
          navs.firstOrNull;
      for (final link in toc?.querySelectorAll('a[href]') ?? <dom.Element>[]) {
        addToc(navPath, link.attributes['href']!, link.text);
      }
    }
  } catch (_) {
    /* A broken navigation document must not prevent reading. */
  }
  if (tocTitles.isEmpty) {
    try {
      final spine = elements.where((e) => e.name.local == 'spine').firstOrNull;
      final ncxItem =
          manifest[spine?.getAttribute('toc')] ??
          manifest.values
              .where(
                (e) =>
                    e.getAttribute('media-type') == 'application/x-dtbncx+xml',
              )
              .firstOrNull;
      if (ncxItem != null) {
        final ncxPath = resolve(ncxItem.getAttribute('href') ?? '');
        for (final point
            in xml(ncxPath).descendants
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'navPoint')) {
          final src = point.childElements
              .where((e) => e.name.local == 'content')
              .firstOrNull
              ?.getAttribute('src');
          if (src == null) continue;
          addToc(
            ncxPath,
            src,
            point.childElements
                .where((e) => e.name.local == 'navLabel')
                .firstOrNull
                ?.innerText,
          );
        }
      }
    } catch (_) {
      /* Optional legacy table of contents. */
    }
  }
  final chapters = <EpubChapter>[];
  final footnoteTargets = <String, dom.Document>{};
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
    if (item == null) continue;
    final mediaType = (item.getAttribute('media-type') ?? '').trim();
    final path = resolve(item.getAttribute('href') ?? '');
    if (!files.containsKey(path)) continue;
    if (const {
      'image/jpeg',
      'image/png',
      'image/gif',
      'image/webp',
    }.contains(mediaType)) {
      // An image page in the reading order (often the cover) is shown before
      // the next text chapter.
      final bytes = artwork(path);
      if (bytes != null) {
        pendingImages.add(BookIllustration('Иллюстрация', bytes));
      }
      continue;
    }
    // SVG pages, scripts and other non-text items are skipped instead of
    // refusing the whole book.
    if (mediaType != 'application/xhtml+xml' && mediaType != 'text/html') {
      continue;
    }
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
    final links =
        <
          ({String href, String label, String sourceType, int start, int end})
        >[];
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
        'dt',
        'dd',
        'blockquote',
        'aside',
        'pre',
        'div',
        'section',
        'article',
        'figure',
        'figcaption',
        'table',
        'caption',
        'tr',
        'br',
      }.contains(tag);
      if (block) flush();
      if (tag == 'td' || tag == 'th') {
        final siblings = node.parent?.children ?? const <dom.Element>[];
        final position = siblings.indexOf(node as dom.Element);
        if (position > 0 &&
            const {'td', 'th'}.contains(siblings[position - 1].localName)) {
          buffer.write('  │  ');
        }
      }
      final linkStart = tag == 'a' && links.length < 2048 ? position() : 0;
      for (final child in node.nodes) {
        visit(child, depth + 1);
      }
      if (node is dom.Element && tag == 'a' && links.length < 2048) {
        final href = node.attributes['href'] ?? '';
        final label = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (href.contains('#') && label.isNotEmpty) {
          links.add((
            href: href,
            label: label,
            sourceType:
                '${node.attributes['epub:type'] ?? ''} ${node.attributes['role'] ?? ''} ${node.className} ${node.parent?.localName == 'sup' ? 'sup' : ''}',
            start: linkStart,
            end: position(),
          ));
        }
      }
      if (block) flush();
    }

    if (body != null) visit(body);
    flush();
    final text = paragraphs.join('\n\n');
    final footnotes = <BookFootnote>[];
    footnoteTargets[path] = document;
    if (footnoteTargets.length > 8) {
      footnoteTargets.remove(footnoteTargets.keys.first);
    }
    for (final link in links) {
      final targetPath = bookResourcePath(path, link.href);
      if (targetPath == null) continue;
      try {
        final target = footnoteTargets.putIfAbsent(
          targetPath,
          () => html.parse(read(targetPath)),
        );
        if (footnoteTargets.length > 8) {
          footnoteTargets.remove(footnoteTargets.keys.first);
        }
        final id = Uri.decodeComponent(Uri.parse(link.href).fragment);
        if (id.isEmpty) continue;
        final element =
            target.getElementById(id) ??
            target
                .querySelectorAll('[name]')
                .where((e) => e.attributes['name'] == id)
                .firstOrNull;
        if (element == null) continue;
        final semantic = [
          link.sourceType,
          for (dom.Element? e = element; e != null; e = e.parent)
            '${e.attributes['epub:type'] ?? ''} ${e.attributes['role'] ?? ''} ${e.className}',
        ].join(' ');
        final noteTarget = RegExp(
          r'(^|[/#_.-])(?:(?:content)?(?:footnotes?|endnotes?|notes?)|ftn|fn|n)[0-9_-]*([/#_.-]|$)',
          caseSensitive: false,
        ).hasMatch('$targetPath#$id');
        final semanticNote = RegExp(
          r'footnote|endnote|noteref|doc-noteref|\bnotes?\b',
          caseSensitive: false,
        ).hasMatch(semantic);
        final numericMarker = RegExp(r'^\[?[0-9⁰¹²³⁴⁵⁶⁷⁸⁹]+\]?$')
            .hasMatch(link.label);
        if (!semanticNote && !(numericMarker && noteTarget)) {
          continue;
        }
        final content = _epubFootnoteText(element);
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
      final pageTitle = _cleanTitle(document.querySelector('title')?.text);
      final title =
          tocTitles[path] ??
          _cleanTitle(body?.querySelector('h1,h2,h3')?.text) ??
          (pageTitle == bookTitle ? null : pageTitle);
      chapters.add(
        EpubChapter(
          path,
          title ?? 'Глава ${chapters.length + 1}',
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
  final extra = <String, dynamic>{};
  final metadataElement = elements
      .where((e) => e.name.local == 'metadata')
      .firstOrNull;
  final raw = <String, List<String>>{};
  for (final e in metadataElement?.childElements ?? <XmlElement>[]) {
    final key = e.name.local == 'meta'
        ? e.getAttribute('property') ?? e.getAttribute('name') ?? 'meta'
        : e.name.local;
    final value = (e.getAttribute('content') ?? e.innerText).trim();
    if (value.isEmpty || value.length > 10000 || raw.length >= 100) continue;
    final values = raw.putIfAbsent(key, () => []);
    if (values.length < 30) values.add(value);
  }
  for (final mapping in {
    'language': 'language',
    'publisher': 'publisher',
    'date': 'publicationDate',
    'subject': 'genres',
    'rights': 'rights',
    'contributor': 'contributors',
  }.entries) {
    final values = raw[mapping.key];
    if (values != null) {
      extra[mapping.value] =
          const {'genres', 'contributors'}.contains(mapping.value)
          ? values
          : values.first;
    }
  }
  final identifiers = raw['identifier'];
  if (identifiers != null) {
    extra['identifiers'] = identifiers;
    final isbn = identifiers
        .where(
          (v) => RegExp(r'^(?:urn:isbn:|isbn:)?[0-9Xx -]{10,20}$').hasMatch(v),
        )
        .firstOrNull;
    if (isbn != null) {
      extra['isbn'] = isbn.replaceFirst(
        RegExp(r'^(urn:)?isbn:', caseSensitive: false),
        '',
      );
    }
  }
  extra['embeddedMetadata'] = raw;
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
    metadata: extra,
  );
}
