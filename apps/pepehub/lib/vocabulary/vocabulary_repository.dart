import 'dart:convert';

import 'package:drift/drift.dart';

import '../data/repository.dart';

enum VocabularyKind { word, sentence }

class VocabularySource {
  final String kind, title, detail;
  final String? mediaId, mediaVersion, trackId;
  final int? positionMs, endMs;
  const VocabularySource({
    required this.kind,
    required this.title,
    this.detail = '',
    this.mediaId,
    this.mediaVersion,
    this.trackId,
    this.positionMs,
    this.endMs,
  });
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'title': title,
    'detail': detail,
    if (mediaId != null) 'mediaId': mediaId,
    if (mediaVersion != null) 'mediaVersion': mediaVersion,
    if (trackId != null) 'trackId': trackId,
    if (positionMs != null) 'positionMs': positionMs,
    if (endMs != null) 'endMs': endMs,
  };
  factory VocabularySource.fromJson(Map<String, dynamic> json) =>
      VocabularySource(
        kind: json['kind'] as String,
        title: json['title'] as String,
        detail: json['detail'] as String? ?? '',
        mediaId: json['mediaId'] as String?,
        mediaVersion: json['mediaVersion'] as String?,
        trackId: json['trackId'] as String?,
        positionMs: json['positionMs'] as int?,
        endMs: json['endMs'] as int?,
      );
  String get label => [
    title,
    if (detail.isNotEmpty) detail,
    if (positionMs != null) vocabularyTime(positionMs!),
  ].join(' · ');
}

String vocabularyTime(int ms) {
  final seconds = ms ~/ 1000;
  return seconds >= 3600
      ? '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class VocabularyCard {
  final String id, front, back, context, deck;
  final VocabularyKind kind;
  final List<String> tags;
  final VocabularySource? source;
  final DateTime createdAt, updatedAt;
  final int revision;
  const VocabularyCard({
    required this.id,
    required this.front,
    required this.back,
    required this.context,
    required this.deck,
    required this.kind,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    this.source,
  });
  Map<String, dynamic> toJson() => {
    'front': front,
    'back': back,
    'context': context,
    'deck': deck,
    'kind': kind.name,
    'tags': tags,
    if (source != null) 'source': source!.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
  factory VocabularyCard.fromRecord(LibraryRecord record) {
    final json = record.payload!;
    return VocabularyCard(
      id: record.id,
      revision: record.revision,
      front: json['front'] as String,
      back: json['back'] as String,
      context: json['context'] as String? ?? '',
      deck: json['deck'] as String,
      kind: json['kind'] == 'sentence'
          ? VocabularyKind.sentence
          : VocabularyKind.word,
      tags: List<String>.unmodifiable((json['tags'] as List).cast<String>()),
      source: json['source'] == null
          ? null
          : VocabularySource.fromJson(
              Map<String, dynamic>.from(json['source'] as Map),
            ),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

/// Local vocabulary stays out of the book synchronization outbox.
class VocabularyRepository {
  final Repository repository;
  const VocabularyRepository(this.repository);

  Future<List<VocabularyCard>> list() async {
    final cards = (await repository.records('vocabulary_card'))
        .map(VocabularyCard.fromRecord)
        .toList();
    cards.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate == 0 ? a.id.compareTo(b.id) : byDate;
    });
    return cards;
  }

  Future<VocabularyCard> save({
    VocabularyCard? existing,
    required String front,
    required String back,
    String context = '',
    String deck = 'PepeHub',
    VocabularyKind kind = VocabularyKind.word,
    List<String> tags = const [],
    VocabularySource? source,
  }) async {
    front = front.trim();
    back = back.trim();
    context = context.trim();
    deck = deck.trim();
    if (front.isEmpty ||
        front.runes.length > 5000 ||
        back.isEmpty ||
        back.runes.length > 20000) {
      throw ArgumentError(
        'Заполните фразу (до 5000 знаков) и перевод (до 20000 знаков)',
      );
    }
    if (context.runes.length > 20000 ||
        deck.isEmpty ||
        deck.runes.length > 200 ||
        deck.contains(RegExp(r'[\x00-\x1f]'))) {
      throw ArgumentError('Проверьте контекст и название колоды');
    }
    final cleanTags =
        tags
            .map((t) => t.trim().replaceAll(RegExp(r'\s+'), '_'))
            .where((t) => t.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (cleanTags.length > 50 || cleanTags.any((t) => t.runes.length > 100)) {
      throw ArgumentError('До 50 тегов длиной до 100 знаков');
    }
    final now = DateTime.now().toUtc();
    final card = VocabularyCard(
      id: existing?.id ?? uuid.v4(),
      revision: (existing?.revision ?? 0) + 1,
      front: front,
      back: back,
      context: context,
      deck: deck,
      kind: kind,
      tags: List.unmodifiable(cleanTags),
      source: existing?.source ?? source,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await repository.db.transaction(() async {
      if (existing == null) {
        await repository.db.customStatement(
          'INSERT INTO records(id,type,revision,deleted,payload) VALUES(?,?,1,0,?)',
          [card.id, 'vocabulary_card', jsonEncode(card.toJson())],
        );
      } else {
        final changed = await repository.db.customUpdate(
          "UPDATE records SET payload=?,revision=revision+1 WHERE id=? "
          "AND type='vocabulary_card' AND deleted=0 AND revision=?",
          variables: [
            Variable(jsonEncode(card.toJson())),
            Variable(card.id),
            Variable(existing.revision),
          ],
        );
        if (changed != 1) {
          throw StateError(
            'Карточка уже изменена. Откройте её заново; введённый текст сохранён в редакторе.',
          );
        }
      }
    });
    return card;
  }

  Future<void> delete(VocabularyCard card) async {
    final changed = await repository.db.customUpdate(
      "UPDATE records SET deleted=1,revision=revision+1 WHERE id=? "
      "AND type='vocabulary_card' AND deleted=0 AND revision=?",
      variables: [Variable(card.id), Variable(card.revision)],
    );
    if (changed != 1) {
      throw StateError('Карточка уже изменена. Обновите список.');
    }
  }
}
