import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';

bool _rtfLetter(int code) =>
    code >= 65 && code <= 90 || code >= 97 && code <= 122;

/// Text projection with emphasis ranges; pictures and embedded objects are ignored.
String rtfText(
  Uint8List bytes, {
  void Function(int start, int end, bool bold, bool italic)? onStyle,
}) {
  final source = latin1.decode(bytes);
  if (!source.startsWith(r'{\rtf1')) throw const FormatException('Это не RTF');
  final output = StringBuffer();
  final stack = <({bool skip, int uc, int cp, bool bold, bool italic})>[];
  var bold = false, italic = false;
  var skip = false, uc = 1, cp = 1252, fallback = 0, i = 0;
  String decode(int value) =>
      (cp == 1251 ? const Windows1251Codec() : const Windows1252Codec()).decode(
        [value],
      );
  void emit(String text) {
    if (fallback > 0) {
      fallback--;
      return;
    }
    if (!skip) {
      if (bold || italic) {
        onStyle?.call(output.length, output.length + text.length, bold, italic);
      }
      output.write(text);
    }
  }

  const destinations = {
    'fonttbl',
    'colortbl',
    'stylesheet',
    'info',
    'pict',
    'object',
    'header',
    'footer',
    'headerl',
    'headerr',
    'footerl',
    'footerr',
    'annotation',
    'filetbl',
    'datastore',
    'generator',
    'listtable',
    'listoverridetable',
    'rsidtbl',
    'xmlnstbl',
    'fldinst',
  };
  while (i < source.length) {
    final ch = source[i++];
    if (ch == '{') {
      if (stack.length >= 256) {
        throw const FormatException('Слишком глубокий RTF');
      }
      stack.add((skip: skip, uc: uc, cp: cp, bold: bold, italic: italic));
      continue;
    }
    if (ch == '}') {
      if (stack.isEmpty) throw const FormatException('Повреждённый RTF');
      final state = stack.removeLast();
      skip = state.skip;
      uc = state.uc;
      cp = state.cp;
      bold = state.bold;
      italic = state.italic;
      continue;
    }
    if (stack.isEmpty) {
      if (ch.trim().isNotEmpty) {
        throw const FormatException('Данные вне документа RTF');
      }
      continue;
    }
    if (ch != r'\') {
      if (ch != '\r' && ch != '\n') emit(decode(ch.codeUnitAt(0)));
      continue;
    }
    if (i >= source.length) throw const FormatException('Повреждённый RTF');
    final symbol = source[i];
    if (symbol == '\\' || symbol == '{' || symbol == '}') {
      i++;
      emit(symbol);
      continue;
    }
    if (symbol == "'") {
      if (i + 2 >= source.length) {
        throw const FormatException('Повреждённый escape RTF');
      }
      final byte = int.tryParse(source.substring(i + 1, i + 3), radix: 16);
      if (byte == null) throw const FormatException('Повреждённый escape RTF');
      i += 3;
      emit(decode(byte));
      continue;
    }
    if (!_rtfLetter(symbol.codeUnitAt(0))) {
      i++;
      if (symbol == '*') skip = true;
      if (symbol == '~') emit(' ');
      if (symbol == '_') emit('-');
      continue;
    }
    final start = i;
    while (i < source.length && _rtfLetter(source.codeUnitAt(i))) {
      i++;
    }
    final word = source.substring(start, i);
    final paramStart = i;
    if (i < source.length && source[i] == '-') i++;
    while (i < source.length &&
        source.codeUnitAt(i) >= 48 &&
        source.codeUnitAt(i) <= 57) {
      i++;
    }
    final number = i > paramStart
        ? int.tryParse(source.substring(paramStart, i))
        : null;
    if (i < source.length && source[i] == ' ') i++;
    if (word == 'b') bold = number != 0;
    if (word == 'i') italic = number != 0;
    if (word == 'plain') {
      bold = false;
      italic = false;
    }
    if (destinations.contains(word)) {
      skip = true;
      continue;
    }
    if (word == 'bin') {
      if (number == null || number < 0 || i + number > source.length) {
        throw const FormatException('Повреждённый binary RTF');
      }
      i += number;
      continue;
    }
    if (word == 'ansicpg') {
      if (number != 1251 && number != 1252) {
        throw const FormatException(
          'RTF: поддерживаются кодировки Windows-1251/1252 и Unicode',
        );
      }
      cp = number!;
    }
    if (word == 'uc') {
      if (number == null || number < 0 || number > 16) {
        throw const FormatException('Некорректный Unicode RTF');
      }
      uc = number;
    }
    if (word == 'u') {
      if (number == null || number < -32768 || number > 65535) {
        throw const FormatException('Некорректный Unicode RTF');
      }
      if (!skip) {
        if (bold || italic) {
          onStyle?.call(output.length, output.length + 1, bold, italic);
        }
        output.writeCharCode(number & 65535);
      }
      fallback = uc;
      continue;
    }
    if (word == 'par' || word == 'line') {
      fallback = 0;
      if (!skip) output.write('\n\n');
    }
    if (word == 'tab') emit(' ');
    final punctuation = const {
      'emdash': '—',
      'endash': '–',
      'bullet': '•',
      'lquote': '‘',
      'rquote': '’',
      'ldblquote': '“',
      'rdblquote': '”',
    }[word];
    if (punctuation != null) emit(punctuation);
  }
  if (stack.isNotEmpty) throw const FormatException('Незакрытая группа RTF');
  return output.toString();
}
