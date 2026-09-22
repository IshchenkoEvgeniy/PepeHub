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

List<BookMarkup> htmlMarkup(dom.Node root, String text) {
  final result = <BookMarkup>[];
  var cursor = 0;
  (int, int)? visit(dom.Node node, int depth) {
    if (depth > 256) return null;
    if (node is dom.Text) {
      var value = node.data.replaceAll(RegExp(r'\s+'), ' ').trim();
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
      final heading = RegExp(r'^h[1-6]$').hasMatch(tag) ? int.parse(tag[1]) : 0;
      final bold =
          const {'b', 'strong', 'dt', 'th'}.contains(tag) ||
          RegExp(r'font-weight\s*:\s*(bold|[6-9]00)').hasMatch(css);
      final italic =
          const {'i', 'em', 'cite'}.contains(tag) ||
          RegExp(r'font-style\s*:\s*italic').hasMatch(css);
      final code =
          const {'pre', 'code', 'samp', 'kbd'}.contains(tag) ||
          css.contains('monospace');
      final align = RegExp(r'text-align\s*:\s*(left|right|center|justify)')
          .firstMatch(css)
          ?.group(1);
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
          : RegExp(r'\b(note|tip|warning|caution|admonition)\b')
                .hasMatch(node.className)
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
