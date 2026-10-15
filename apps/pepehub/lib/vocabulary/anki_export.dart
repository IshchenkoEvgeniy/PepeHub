import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../audio/audio_folder.dart';
import 'vocabulary_repository.dart';

/// Basic/«Обычный» notes: front, back (with context/source), tags and deck.
/// Import uses Anki's normal first-field matching; no invented Anki GUIDs.
String ankiText(List<VocabularyCard> cards) {
  String html(String text) =>
      const HtmlEscape(HtmlEscapeMode.element)
          .convert(text)
          .replaceAll('"', '&quot;')
          .replaceAll('#', '&#35;')
          .replaceAll('\t', '&#9;')
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .replaceAll('\n', '<br>');
  String field(String text) => '"${text.replaceAll('"', '""')}"';
  final out = StringBuffer(
    '#separator:Tab\n#html:true\n#tags column:3\n#deck column:4\n'
    '#columns:Front\tBack\tTags\tDeck\n',
  );
  for (final card in cards) {
    final back = StringBuffer(html(card.back));
    if (card.context.isNotEmpty) back.write('<br><br>${html(card.context)}');
    if (card.source != null) {
      back.write('<br><br><small>${html(card.source!.label)}</small>');
    }
    out.writeln(
      [
        html(card.front),
        back.toString(),
        {'PepeHub', 'PepeHub::${card.kind.name}', ...card.tags}.join(' '),
        card.deck,
      ].map(field).join('\t'),
    );
  }
  return out.toString();
}

Future<bool> saveAnkiExport(List<VocabularyCard> cards) async {
  if (cards.isEmpty) throw StateError('Выберите хотя бы одну карточку');
  final text = ankiText(cards);
  if (utf8.encode(text).length > 16 * 1024 * 1024) {
    throw StateError('Экспорт больше 16 МиБ. Выберите меньше карточек.');
  }
  final name =
      'PepeHub-Anki-${DateTime.now().toIso8601String().substring(0, 10)}.txt';
  if (Platform.isAndroid) {
    return await audioFolderChannel.invokeMethod<bool>('exportStatistics', {
          'name': name,
          'mime': 'text/plain',
          'text': text,
        }) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Anki (UTF-8)', extensions: ['txt']),
    ],
  );
  if (location == null) return false;
  await File(location.path).writeAsString(text, encoding: utf8, flush: true);
  return true;
}
