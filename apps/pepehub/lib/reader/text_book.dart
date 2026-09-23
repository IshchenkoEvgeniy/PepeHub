import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'book_archive.dart';
import 'book_formats.dart';
import 'epub.dart';
import 'rtf.dart';

Future<EpubBook> loadTextBook(
  String path,
  String filename, {
  bool legacyProjection = false,
}) => Isolate.run(() {
  final file = File(path);
  if (file.lengthSync() > 64 * 1024 * 1024) {
    throw const FormatException('Книга превышает 64 МБ');
  }
  final bytes = file.readAsBytesSync();
  final localImages = <String, Uint8List>{};
  final format = bookFormat(filename);
  if (format == 'html' || format == 'md') {
    var source = decodeBookText(bytes);
    if (format == 'md') source = md.markdownToHtml(source);
    var total = 0;
    for (final image in html.parse(source).querySelectorAll('img')) {
      final href = image.attributes['src'] ?? '';
      final relative = bookResourcePath(p.basename(path), href);
      if (relative == null ||
          localImages.containsKey(href) ||
          localImages.length >= 64) {
        continue;
      }
      final resource = File(p.join(p.dirname(path), relative));
      if (!resource.existsSync()) continue;
      final size = resource.lengthSync();
      if (size > 4 * 1024 * 1024 || total + size > 12 * 1024 * 1024) continue;
      total += size;
      localImages[href] = resource.readAsBytesSync();
    }
  }
  return parseTextBook(
    bytes,
    filename,
    localImages: localImages,
    legacyProjection: legacyProjection,
  );
});

String decodeBookText(Uint8List bytes) {
  String result;
  if (bytes.length >= 3 &&
      bytes[0] == 239 &&
      bytes[1] == 187 &&
      bytes[2] == 191) {
    result = utf8.decode(bytes);
  } else if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    if (bytes.length.isOdd) throw const FormatException('Повреждённый UTF-16');
    final little = bytes[0] == 255;
    final units = <int>[];
    for (var i = 2; i < bytes.length; i += 2) {
      units.add(
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      );
    }
    result = String.fromCharCodes(units);
    for (var i = 0; i < units.length; i++) {
      if (units[i] >= 0xD800 && units[i] <= 0xDBFF) {
        if (++i >= units.length || units[i] < 0xDC00 || units[i] > 0xDFFF) {
          throw const FormatException('Повреждённый UTF-16');
        }
      } else if (units[i] >= 0xDC00 && units[i] <= 0xDFFF) {
        throw const FormatException('Повреждённый UTF-16');
      }
    }
  } else {
    final prefix = latin1.decode(bytes.take(1024).toList()).toLowerCase();
    final declared = RegExp('(?:encoding|charset)\\s*=\\s*["\']?([a-z0-9_-]+)')
        .firstMatch(prefix)
        ?.group(1);
    result = switch (declared) {
      'windows-1251' || 'cp1251' => const Windows1251Codec().decode(bytes),
      'windows-1252' || 'cp1252' => const Windows1252Codec().decode(bytes),
      'koi8-r' => const Koi8rCodec().decode(bytes),
      'koi8-u' => const Koi8uCodec().decode(bytes),
      null ||
      'utf-8' ||
      'utf8' ||
      'us-ascii' => _utf8OrCyrillic(bytes, allowFallback: declared == null),
      _ => throw FormatException(
        'Неподдерживаемая кодировка $declared. Сохраните книгу в UTF-8.',
      ),
    };
  }
  result = result.replaceFirst(RegExp('^\uFEFF'), '');
  if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(result)) {
    throw const FormatException('Файл содержит двоичные данные');
  }
  return result;
}

String _utf8OrCyrillic(Uint8List bytes, {required bool allowFallback}) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    if (!allowFallback) rethrow;
    return const Windows1251Codec().decode(bytes);
  }
}

List<String> htmlParagraphs(String source, {bool legacyProjection = false}) {
  final document = html.parse(source);
  if (legacyProjection) {
    for (final node in document.querySelectorAll('svg,nav')) {
      node.remove();
    }
  }
  for (final e in document.querySelectorAll(
    'script,style,iframe,object,head',
  )) {
    e.remove();
  }
  final result = <String>[];
  var buffer = StringBuffer();
  void flush() {
    final text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) result.add(text);
    buffer = StringBuffer();
  }

  void visit(dom.Node node, int depth) {
    if (depth > 256) throw const FormatException('Слишком глубокая разметка');
    if (node is dom.Text) {
      buffer.write(node.data);
      return;
    }
    final tag = node is dom.Element ? node.localName : null;
    if (!legacyProjection && node is dom.Element && tag == 'pre') {
      flush();
      final code = node.text.trim();
      if (code.isNotEmpty) result.add(code);
      return;
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
    if (node is dom.Element && (tag == 'td' || tag == 'th')) {
      final parent = node.parent;
      final siblings = parent is dom.Element
          ? parent.children
          : const <dom.Element>[];
      final position = siblings.indexOf(node);
      if (position > 0 &&
          const {'td', 'th'}.contains(siblings[position - 1].localName)) {
        buffer.write('  │  ');
      }
    }
    for (final child in node.nodes) {
      visit(child, depth + 1);
    }
    if (block) flush();
  }

  if (document.body != null) visit(document.body!, 0);
  flush();
  return result;
}

XmlDocument _xml(Uint8List bytes) {
  final source = decodeBookText(bytes);
  if (source.contains('<!ENTITY') || source.contains('<!DOCTYPE')) {
    throw const FormatException('DTD и XML entities не поддерживаются');
  }
  return XmlDocument.parse(source);
}

EpubBook parseTextBook(
  Uint8List bytes,
  String filename, {
  Map<String, Uint8List> localImages = const {},
  bool legacyProjection = false,
}) {
  if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) {
    throw const FormatException('Недопустимый размер книги');
  }
  final format = bookFormat(filename);
  if (const {'txt', 'md', 'html', 'rtf'}.contains(format) &&
      bytes.length > 16 * 1024 * 1024) {
    throw const FormatException('Текстовый файл превышает 16 МБ');
  }
  if (format == 'epub') {
    return parseEpub(bytes, legacyProjection: legacyProjection);
  }
  var title = p.basenameWithoutExtension(filename);
  final authors = <String>[];
  String? series, seriesNumber, description;
  Uint8List? cover;
  final chapters = <EpubChapter>[];
  void chapter(String label, List<String> paragraphs, {dom.Node? rich}) {
    if (paragraphs.isNotEmpty) {
      chapters.add(
        EpubChapter(
          'section-${chapters.length}',
          label,
          paragraphs,
          markup: rich == null
              ? const []
              : htmlMarkup(rich, paragraphs.join('\n\n')),
        ),
      );
    }
  }

  if (format == 'fb2') {
    if (filename.toLowerCase().endsWith('.zip')) {
      final zip = BookArchive(bytes);
      final matches = zip.entries.keys
          .where((s) => s.toLowerCase().endsWith('.fb2'))
          .toList();
      if (matches.length != 1) {
        throw const FormatException('FB2.ZIP должен содержать одну книгу FB2');
      }
      bytes = zip.read(matches.single);
    }
    final doc = _xml(bytes);
    if (doc.rootElement.name.local != 'FictionBook') {
      throw const FormatException('Это не FB2');
    }
    final info = doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'title-info')
        .firstOrNull;
    title =
        info?.childElements
            .where((e) => e.name.local == 'book-title')
            .firstOrNull
            ?.innerText
            .trim() ??
        title;
    for (final author
        in info?.childElements.where((e) => e.name.local == 'author') ??
            <XmlElement>[]) {
      final parts = author.childElements
          .where(
            (e) => const {
              'first-name',
              'middle-name',
              'last-name',
            }.contains(e.name.local),
          )
          .map((e) => e.innerText.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final name = parts.isEmpty
          ? author.childElements
                .where((e) => e.name.local == 'nickname')
                .firstOrNull
                ?.innerText
                .trim()
          : parts.join(' ');
      if (name != null && name.isNotEmpty) authors.add(name);
    }
    final sequence = info?.childElements
        .where((e) => e.name.local == 'sequence')
        .firstOrNull;
    series = sequence?.getAttribute('name');
    seriesNumber = sequence?.getAttribute('number');
    description = info?.childElements
        .where((e) => e.name.local == 'annotation')
        .firstOrNull
        ?.innerText
        .trim();
    final image = info?.childElements
        .where((e) => e.name.local == 'coverpage')
        .firstOrNull
        ?.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'image')
        .firstOrNull;
    final href = image?.attributes
        .where((a) => a.name.local == 'href')
        .firstOrNull
        ?.value;
    if (href != null && href.startsWith('#')) {
      final binary = doc.rootElement.childElements
          .where(
            (e) =>
                e.name.local == 'binary' &&
                e.getAttribute('id') == href.substring(1),
          )
          .firstOrNull;
      if (binary != null && binary.innerText.length < 6 * 1024 * 1024) {
        try {
          cover = base64Decode(binary.innerText.replaceAll(RegExp(r'\s'), ''));
        } on FormatException {
          /* Invalid optional cover. */
        }
      }
    }
    final byId = <String, XmlElement>{
      for (final e in doc.descendants.whereType<XmlElement>())
        if (e.getAttribute('id') != null) e.getAttribute('id')!: e,
    };
    final images = <String, Uint8List>{};
    var imageBytes = 0;
    void attachResources(XmlElement section, int before) {
      if (chapters.length == before) return;
      final previous = chapters.last;
      final text = previous.paragraphs.join('\n\n');
      final footnotes = <BookFootnote>[];
      final illustrations = <BookIllustration>[];
      final seenImages = <String>{};
      final anchors = <XmlElement, int>{};
      final imageOffsets = <XmlElement, int>{};
      var paragraphOffset = 0;
      void indexParagraphs(XmlElement node) {
        if (node.name.local == 'image') imageOffsets[node] = paragraphOffset;
        if (const {
          'p',
          'v',
          'subtitle',
          'text-author',
        }.contains(node.name.local)) {
          final normalized = node.innerText
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (normalized.isEmpty) return;
          final prefix = StringBuffer();
          void walk(XmlNode child) {
            if (child is XmlText) {
              prefix.write(child.value);
              return;
            }
            if (child is XmlElement && child.name.local == 'a') {
              anchors[child] =
                  paragraphOffset +
                  prefix
                      .toString()
                      .replaceAll(RegExp(r'\s+'), ' ')
                      .trimLeft()
                      .length;
            }
            for (final sub in child.children) {
              walk(sub);
            }
          }

          walk(node);
          paragraphOffset += normalized.length + 2;
        } else {
          for (final child in node.childElements) {
            indexParagraphs(child);
          }
        }
      }

      indexParagraphs(section);
      for (final e in section.descendants.whereType<XmlElement>()) {
        final href = e.attributes
            .where((a) => a.name.local == 'href')
            .firstOrNull
            ?.value;
        if (href == null || !href.startsWith('#')) continue;
        final id = href.substring(1), target = byId[href.substring(1)];
        if (target == null) continue;
        if (e.name.local == 'a' &&
            e.getAttribute('type') == 'note' &&
            footnotes.length < 256) {
          final label = e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
          final content = _fbParagraphs(target).join('\n\n');
          final start = anchors[e] ?? -1;
          if (start >= 0 && content.isNotEmpty && content.length <= 32000) {
            if (start + label.length <= text.length &&
                text.substring(start, start + label.length) == label) {
              footnotes.add(
                BookFootnote(label, content, start, start + label.length),
              );
            }
          }
        }
        if (e.name.local == 'image' &&
            target.name.local == 'binary' &&
            illustrations.length < 64 &&
            seenImages.add(id)) {
          if (!images.containsKey(id) &&
              target.innerText.length < 6 * 1024 * 1024 &&
              imageBytes < 12 * 1024 * 1024) {
            try {
              final bytes = base64Decode(
                target.innerText.replaceAll(RegExp(r'\s'), ''),
              );
              if (imageBytes + bytes.length <= 12 * 1024 * 1024) {
                images[id] = bytes;
                imageBytes += bytes.length;
              }
            } on FormatException {
              /* Optional invalid illustration. */
            }
          }
          if (images[id] != null) {
            illustrations.add(
              BookIllustration(
                'Иллюстрация ${illustrations.length + 1}',
                images[id]!,
                offset: imageOffsets[e] ?? paragraphOffset,
              ),
            );
          }
        }
      }
      chapters[chapters.length - 1] = EpubChapter(
        previous.path,
        previous.title,
        previous.paragraphs,
        footnotes: footnotes,
        illustrations: illustrations,
        markup: htmlMarkup(
          html.parse(
            section
                .toXmlString()
                .replaceAll('<title>', '<h2>')
                .replaceAll('</title>', '</h2>')
                .replaceAll('<emphasis>', '<em>')
                .replaceAll('</emphasis>', '</em>')
                .replaceAll('<subtitle>', '<h3>')
                .replaceAll('</subtitle>', '</h3>'),
          ),
          text,
        ),
      );
    }

    for (final body in doc.rootElement.childElements.where(
      (e) => e.name.local == 'body',
    )) {
      final sections = body.childElements
          .where((e) => e.name.local == 'section')
          .toList();
      // Top-level body text is kept, nested sections remain in their original order.
      var loose = <String>[];
      for (final node in body.childElements) {
        if (node.name.local == 'section') {
          chapter('Вступление', loose);
          loose = [];
          final heading = node.childElements
              .where((e) => e.name.local == 'title')
              .firstOrNull
              ?.innerText
              .trim();
          final before = chapters.length;
          chapter(
            heading == null || heading.isEmpty
                ? 'Раздел ${chapters.length + 1}'
                : heading,
            _fbParagraphs(node),
          );
          attachResources(node, before);
        } else {
          loose.addAll(_fbParagraphs(node));
        }
      }
      chapter(sections.isEmpty ? title : 'Примечания', loose);
    }
  } else if (format == 'docx') {
    final zip = BookArchive(bytes);
    final doc = _xml(zip.read('word/document.xml'));
    if (zip.entries.containsKey('docProps/core.xml')) {
      final core = _xml(zip.read('docProps/core.xml'));
      for (final e in core.descendants.whereType<XmlElement>()) {
        if (e.name.local == 'title' && e.innerText.trim().isNotEmpty) {
          title = e.innerText.trim();
        }
        if (e.name.local == 'creator' && e.innerText.trim().isNotEmpty) {
          authors.add(e.innerText.trim());
        }
      }
    }
    final thumbnail = zip.entries.keys
        .where(
          (s) => RegExp(
            r'^docProps/thumbnail\.(jpeg|jpg|png)$',
            caseSensitive: false,
          ).hasMatch(s),
        )
        .firstOrNull;
    if (thumbnail != null) {
      try {
        cover = zip.read(thumbnail, limit: 4 * 1024 * 1024);
      } on FormatException {
        /* Optional thumbnail. */
      }
    }
    final paragraphs = <String>[];
    final rich = <BookMarkup>[];
    final illustrations = <BookIllustration>[];
    final relationships = <String, String>{};
    if (zip.entries.containsKey('word/_rels/document.xml.rels')) {
      for (final e in _xml(
        zip.read('word/_rels/document.xml.rels'),
      ).descendants.whereType<XmlElement>()) {
        final id = e.getAttribute('Id'), target = e.getAttribute('Target');
        if (id != null &&
            target != null &&
            e.getAttribute('TargetMode') != 'External') {
          relationships[id] = target;
        }
      }
    }
    var illustrationBytes = 0;
    var paragraphStart = 0;
    for (final para in doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'p',
    )) {
      final buffer = StringBuffer();
      for (final image in para.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'blip',
      )) {
        final id = image.attributes
            .where((a) => a.name.local == 'embed')
            .firstOrNull
            ?.value;
        final target = relationships[id];
        final path = target == null
            ? null
            : bookResourcePath('word/document.xml', target);
        if (path == null ||
            !zip.entries.containsKey(path) ||
            illustrations.length >= 64) {
          continue;
        }
        try {
          final bytes = zip.read(path, limit: 4 * 1024 * 1024);
          if (illustrationBytes + bytes.length > 12 * 1024 * 1024) continue;
          illustrationBytes += bytes.length;
          illustrations.add(
            BookIllustration(
              'Иллюстрация ${illustrations.length + 1}',
              bytes,
              offset: paragraphStart,
            ),
          );
        } on FormatException {
          /* Unsupported optional image. */
        }
      }
      for (final e in para.descendants.whereType<XmlElement>()) {
        if (e.name.local == 't') buffer.write(e.innerText);
        if (const {'tab', 'br', 'cr'}.contains(e.name.local)) buffer.write(' ');
      }
      final text = buffer.toString().trim();
      if (text.isNotEmpty) {
        paragraphs.add(text);
        final headingStyle = para.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'pStyle')
            .firstOrNull;
        final headingName =
            headingStyle?.attributes
                .where((a) => a.name.local == 'val')
                .firstOrNull
                ?.value ??
            '';
        final heading = RegExp(
          r'heading([1-6])',
          caseSensitive: false,
        ).firstMatch(headingName);
        if (heading != null) {
          rich.add(
            BookMarkup(
              paragraphStart,
              paragraphStart + text.length,
              heading: int.parse(heading.group(1)!),
            ),
          );
        }
        var cursor = 0;
        for (final run in para.descendants.whereType<XmlElement>().where(
          (e) => e.name.local == 'r',
        )) {
          final value = run.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText)
              .join();
          final at = text.indexOf(value, cursor);
          if (value.isEmpty || at < 0) continue;
          cursor = at + value.length;
          bool enabled(String name) =>
              run.descendants.whereType<XmlElement>().any(
                (e) =>
                    e.name.local == name &&
                    !e.attributes.any(
                      (a) =>
                          a.name.local == 'val' &&
                          const {'0', 'false', 'off'}.contains(a.value),
                    ),
              );
          rich.add(
            BookMarkup(
              paragraphStart + at,
              paragraphStart + cursor,
              bold: enabled('b'),
              italic: enabled('i'),
            ),
          );
        }
        paragraphStart += text.length + 2;
      }
    }
    chapter(title, paragraphs);
    if (chapters.isNotEmpty) {
      final previous = chapters.removeLast();
      chapters.add(
        EpubChapter(
          previous.path,
          previous.title,
          previous.paragraphs,
          markup: rich,
          illustrations: illustrations,
        ),
      );
    }
  } else if (format == 'html' || format == 'md') {
    var source = decodeBookText(bytes);
    if (format == 'md') {
      source = md.markdownToHtml(
        source,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
    }
    final heading = html.parse(source).querySelector('title,h1')?.text.trim();
    final author = html
        .parse(source)
        .querySelector('meta[name="author"]')
        ?.attributes['content']
        ?.trim();
    if (author != null && author.isNotEmpty) authors.add(author);
    if (heading != null && heading.isNotEmpty) title = heading;
    final richDocument = html.parse(source);
    applyBookCss(
      richDocument,
      richDocument.querySelectorAll('style').map((e) => e.text).toList(),
    );
    chapter(
      title,
      htmlParagraphs(source, legacyProjection: legacyProjection),
      rich: richDocument,
    );
    if (chapters.isNotEmpty) {
      final previous = chapters.removeLast();
      final text = previous.paragraphs.join('\n\n');
      final pictures = <BookIllustration>[];
      var offset = 0, total = 0;
      void visit(dom.Node node) {
        if (node is dom.Text) {
          final value = node.data.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (value.isNotEmpty) {
            final at = text.indexOf(value, offset);
            if (at >= 0) offset = at + value.length;
          }
        }
        if (node is dom.Element &&
            node.localName == 'img' &&
            pictures.length < 64) {
          final src = node.attributes['src'] ?? '';
          Uint8List? image = localImages[src];
          if (src.startsWith('data:image/')) {
            try {
              image = Uri.parse(src).data?.contentAsBytes();
            } on FormatException {
              /* Invalid optional data URL. */
            }
          }
          if (image != null &&
              image.length <= 4 * 1024 * 1024 &&
              total + image.length <= 12 * 1024 * 1024) {
            total += image.length;
            pictures.add(
              BookIllustration(
                node.attributes['alt'] ?? 'Иллюстрация',
                image,
                offset: offset,
              ),
            );
          }
        }
        for (final child in node.nodes) {
          visit(child);
        }
      }

      final body = html.parse(source).body;
      if (body != null) visit(body);
      chapters.add(
        EpubChapter(
          previous.path,
          previous.title,
          previous.paragraphs,
          markup: previous.markup,
          illustrations: pictures,
        ),
      );
    }
  } else if (format == 'txt' || format == 'rtf') {
    final styles = <BookMarkup>[];
    final source = format == 'rtf'
        ? rtfText(
            bytes,
            onStyle: (start, end, bold, italic) {
              if (styles.isNotEmpty &&
                  styles.last.end == start &&
                  styles.last.bold == bold &&
                  styles.last.italic == italic) {
                start = styles.removeLast().start;
              }
              styles.add(BookMarkup(start, end, bold: bold, italic: italic));
            },
          )
        : decodeBookText(bytes);
    chapter(
      title,
      source
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split(RegExp(r'\n\s*\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
    if (styles.isNotEmpty && chapters.isNotEmpty) {
      final previous = chapters.removeLast();
      var sourceOffset = 0, targetOffset = 0;
      final mapped = <BookMarkup>[];
      for (final paragraph in previous.paragraphs) {
        final at = source.indexOf(paragraph, sourceOffset);
        if (at >= 0) {
          for (final style in styles.where(
            (r) => r.start < at + paragraph.length && r.end > at,
          )) {
            mapped.add(
              BookMarkup(
                targetOffset + (style.start - at).clamp(0, paragraph.length),
                targetOffset + (style.end - at).clamp(0, paragraph.length),
                bold: style.bold,
                italic: style.italic,
              ),
            );
          }
          sourceOffset = at + paragraph.length;
        }
        targetOffset += paragraph.length + 2;
      }
      chapters.add(
        EpubChapter(
          previous.path,
          previous.title,
          previous.paragraphs,
          markup: mapped,
        ),
      );
    }
  } else {
    throw const FormatException('PDF открывается в просмотрщике страниц');
  }
  if (chapters.isEmpty) {
    throw const FormatException('В книге нет читаемого текста');
  }
  return EpubBook(
    title,
    authors.take(30).toList(),
    chapters,
    series: series,
    description: description,
    seriesNumber: seriesNumber,
    cover: cover,
  );
}

List<String> _fbParagraphs(XmlElement root) {
  final output = <String>[];
  void visit(XmlElement e, int depth) {
    if (depth > 256) {
      throw const FormatException('Слишком глубокая структура FB2');
    }
    if (const {'p', 'v', 'subtitle', 'text-author'}.contains(e.name.local)) {
      final text = e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) output.add(text);
    } else {
      for (final child in e.childElements) {
        visit(child, depth + 1);
      }
    }
  }

  visit(root, 0);
  return output;
}
