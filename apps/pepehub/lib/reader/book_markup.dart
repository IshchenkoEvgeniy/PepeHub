import 'package:html/dom.dart' as dom;

/// Presentation ranges use the original text offsets used by notes and logs.
class BookMarkup {
  final int start, end, heading, depth;
  final bool bold, italic, code;
  final String? href, anchor, block, marker, align;
  const BookMarkup(
    this.start,
    this.end, {
    this.heading = 0,
    this.depth = 0,
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.href,
    this.anchor,
    this.block,
    this.marker,
    this.align,
  });
}

/// Exactly `value.replaceAll(RegExp(r'\s+'), ' ')`, without the RegExp
/// engine.
///
/// Book parsers normalize every paragraph, text node and link label this way;
/// the regular expression took about half of the parsing time. Saved
/// positions, notes and bookmarks are offsets into the result, so the
/// whitespace set is Dart's `\s`, code unit for code unit.
String collapseBookWhitespace(String value) {
  final length = value.length;
  var i = 0;
  // Most text already has single spaces only: return it without copying.
  while (i < length) {
    final c = value.codeUnitAt(i);
    if (isRegExpWhitespace(c) &&
        (c != 0x20 ||
            (i + 1 < length && isRegExpWhitespace(value.codeUnitAt(i + 1))))) {
      break;
    }
    i++;
  }
  if (i == length) return value;
  final out = StringBuffer(value.substring(0, i));
  while (i < length) {
    if (isRegExpWhitespace(value.codeUnitAt(i))) {
      out.writeCharCode(0x20);
      i++;
      while (i < length && isRegExpWhitespace(value.codeUnitAt(i))) {
        i++;
      }
    } else {
      final start = i;
      while (i < length && !isRegExpWhitespace(value.codeUnitAt(i))) {
        i++;
      }
      out.write(value.substring(start, i));
    }
  }
  return out.toString();
}

/// Whether a UTF-16 code unit matches `\s` in a Dart [RegExp].
bool isRegExpWhitespace(int c) {
  if (c > 0x20 && c < 0xa0) return false;
  return c == 0x20 ||
      (c >= 0x09 && c <= 0x0d) ||
      c == 0xa0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200a) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202f ||
      c == 0x205f ||
      c == 0x3000 ||
      c == 0xfeff;
}

// Compiled once: htmlMarkup runs these for every element of a book.
final _headingTag = RegExp(r'^h[1-6]$');
final _boldStyle = RegExp(r'font-weight\s*:\s*(bold|[6-9]00)');
final _italicStyle = RegExp(r'font-style\s*:\s*italic');
final _alignStyle = RegExp(r'text-align\s*:\s*(left|right|center|justify)');
final _asideClass = RegExp(r'\b(note|tip|warning|caution|admonition)\b');

List<BookMarkup> htmlMarkup(dom.Node root, String text) {
  final result = <BookMarkup>[];
  var cursor = 0;
  (int, int)? visit(dom.Node node, int depth) {
    if (depth > 256) return null;
    if (node is dom.Text) {
      var value = collapseBookWhitespace(node.data).trim();
      if (value.isEmpty) return null;
      var start = text.indexOf(value, cursor);
      if (start < 0) {
        value = node.data.trim();
        start = text.indexOf(value, cursor);
      }
      if (start < 0) return null;
      cursor = start + value.length;
      return (start, cursor);
    }
    if (node is dom.Element &&
        const {
          'head',
          'script',
          'style',
          'iframe',
          'object',
        }.contains(node.localName)) {
      return null;
    }
    int? start, end;
    for (final child in node.nodes) {
      final range = visit(child, depth + 1);
      if (range == null) continue;
      start ??= range.$1;
      end = range.$2;
    }
    if (node is dom.Element && start != null && end != null) {
      final tag = node.localName ?? '';
      final css = node.attributes['style'] ?? '';
      final heading = _headingTag.hasMatch(tag) ? int.parse(tag[1]) : 0;
      final bold =
          const {'b', 'strong', 'dt', 'th'}.contains(tag) ||
          _boldStyle.hasMatch(css);
      final italic =
          const {'i', 'em', 'cite'}.contains(tag) || _italicStyle.hasMatch(css);
      final code =
          const {'pre', 'code', 'samp', 'kbd'}.contains(tag) ||
          css.contains('monospace');
      final align = _alignStyle.firstMatch(css)?.group(1);
      final block =
          const {
            'li',
            'blockquote',
            'pre',
            'aside',
            'dt',
            'dd',
            'td',
            'th',
          }.contains(tag)
          ? tag
          : _asideClass.hasMatch(
              '${node.className} ${node.attributes['epub:type'] ?? ''} ${node.attributes['role'] ?? ''}',
            )
          ? 'aside'
          : null;
      var nesting = 0;
      for (var parent = node.parent; parent != null; parent = parent.parent) {
        if (parent.localName == 'ul' || parent.localName == 'ol') nesting++;
      }
      final href = tag == 'a' ? node.attributes['href'] : null;
      final anchor = node.attributes['id'];
      if (heading > 0 ||
          bold ||
          italic ||
          code ||
          href != null ||
          anchor != null ||
          align != null ||
          block != null) {
        result.add(
          BookMarkup(
            start,
            end,
            heading: heading,
            bold: bold,
            italic: italic,
            code: code,
            href: href,
            anchor: anchor,
            block: block,
            align: align,
            marker: tag == 'li'
                ? (node.parent?.localName == 'ol'
                      ? '${(node.parent!.children.where((e) => e.localName == 'li').toList().indexOf(node)) + 1}.'
                      : '•')
                : null,
            depth: nesting,
          ),
        );
      }
    }
    return start == null ? null : (start, end!);
  }

  visit(root, 0);
  return result;
}

/// Apply bounded local CSS declarations; scripts, imports and remote assets are
/// never loaded. User font sizing and palette remain controlled by the reader.
void applyBookCss(dom.Document document, Iterable<String> stylesheets) {
  var count = 0;
  for (final sheet in stylesheets) {
    if (sheet.length > 512 * 1024) continue;
    for (final rule in RegExp(
      r'([^{}]+)\{([^{}]*)\}',
    ).allMatches(sheet.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ''))) {
      if (++count > 2000) return;
      final selector = rule.group(1)!.trim();
      if (selector.startsWith('@') || selector.length > 1000) continue;
      final declarations = rule
          .group(2)!
          .split(';')
          .where(
            (s) => RegExp(
              r'^\s*(font-weight|font-style|font-family|text-align)\s*:',
            ).hasMatch(s),
          )
          .join(';');
      if (declarations.isEmpty) continue;
      try {
        for (final node in document.querySelectorAll(selector)) {
          node.attributes['style'] =
              '$declarations;${node.attributes['style'] ?? ''}';
        }
      } on FormatException {
        /* Unsupported selector. */
      }
    }
  }
}
