import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../reader/reading_library.dart';
import 'library_repository.dart';
import 'metadata_values.dart';
import 'models.dart';
import 'personal_library.dart';
import 'activity_store.dart';
import 'note_store.dart';

/// Stores of the former Obsidian Companion connector. They are only read to
/// migrate old cards, notes and history into the personal catalog; nothing is
/// sent anywhere.
class LibraryExchange {
  final Repository local;
  final LibraryRepository catalog;
  final String namespace;
  LibraryExchange(this.local, this.catalog, this.namespace);
  LibraryRepository get remote => LibraryRepository(local, namespace);
  String get key => 'library-exchange:$namespace';

  Future<Map<String, dynamic>> bindings() => ReadingLibrary(local).value(key);

  static Future<void> detachRemovedCards(
    Repository local,
    Set<String> ids,
  ) async {
    const prefix = 'library-exchange:';
    final connectors = await ReadingLibrary(local).entries(prefix);
    for (final connector in connectors.entries) {
      final links = connector.value;
      var changed = false;
      for (final id in ids) {
        final link = links[id];
        if (link is! Map || link['remoteId'] is! String) continue;
        links[id] = {
          'remoteId': link['remoteId'],
          'detached': true,
          'state': 'purged',
        };
        changed = true;
      }
      if (changed) {
        await local.setMeta('$prefix${connector.key}', jsonEncode(links));
      }
    }
  }

  Future<void> journals({bool send = false}) async {
    final links = await bindings();
    final byRemote = {
      for (final e in links.entries)
        if ((e.value as Map)['state'] != 'purged')
          (e.value as Map)['remoteId']: e.key,
    };
    for (final notes in [false, true]) {
      final ActivityStore source = notes
          ? NoteStore(local, namespace)
          : ActivityStore(local, namespace);
      final ActivityStore target = notes
          ? NoteStore(local, personalLibraryNamespace, catalog: catalog)
          : ActivityStore(local, personalLibraryNamespace, catalog: catalog);
      await target.capture();
      final remoteSlots = (await source.state())['slots'] as Map;
      if (send) {
        for (final slot
            in ((await target.state())['slots'] as Map).values
                .whereType<Map>()) {
          if (slot['connector'] != namespace || slot['conflict'] != null) {
            continue;
          }
          final remoteId = slot['remoteId'] as String;
          final remoteSlot = remoteSlots[remoteId] as Map?;
          if (remoteSlot == null) continue;
          if (notes && slot['source'] != null && remoteSlot['source'] == null) {
            // Linking a file after import must materialize one native note,
            // shared by both catalogs, rather than one note per connector ID.
            await source.mutate((state) async {
              final live = (state['slots'] as Map)[remoteId] as Map;
              live['source'] = Map<String, dynamic>.from(slot['source'] as Map);
              live['native'] = Map<String, dynamic>.from(live['value'] as Map);
            });
          }
          if (sameMetadataValue(slot['value'], slot['synced']) &&
              remoteSlot['conflict'] == null) {
            continue;
          }
          final next = {
            ...Map<String, dynamic>.from(slot['value'] as Map),
            'id': remoteId,
            'itemId': (remoteSlot['value'] as Map)['itemId'],
          };
          if (remoteSlot['conflict'] != null) {
            await source.resolve(remoteId, useRemote: true);
          }
          final live =
              ((await source.state())['slots'] as Map)[remoteId] as Map;
          if (!sameMetadataValue(next, live['value'])) {
            await source.edit(remoteId, next);
          }
        }
        continue;
      }
      await target.mutate((state) async {
        final slots = state['slots'] as Map;
        for (final e in remoteSlots.entries) {
          final slot = e.value as Map;
          final original = slot['value'] as Map;
          final itemId = byRemote[original['itemId']];
          if (itemId == null) continue;
          // Native sessions/notes are captured from their original sources,
          // keeping a remote mirror from creating a second local copy.
          if (slot['source'] != null) continue;
          final id = uuid.v5(
            itemId,
            '${notes ? 'note' : 'activity'}:$namespace:${e.key}',
          );
          Map<String, dynamic> translate(Map value) => {
            ...Map<String, dynamic>.from(value),
            'id': id,
            'itemId': itemId,
          };
          final value = translate(original);
          final old = slots[id] as Map?;
          final base = old?['synced'];
          if (old != null &&
              !sameMetadataValue(old['value'], base) &&
              !sameMetadataValue(old['value'], value)) {
            if (!sameMetadataValue(base, value)) {
              old['conflict'] = {
                'entry': value,
                'revision': slot['revision'],
                'sequence': 1,
              };
            }
            continue;
          }
          slots[id] = {
            'value': value,
            'synced': value,
            'revision': slot['revision'] ?? 0,
            'connector': namespace,
            'remoteId': e.key,
            if (slot['conflict'] is Map)
              'conflict': {
                ...Map<String, dynamic>.from(slot['conflict'] as Map),
                'entry': translate((slot['conflict'] as Map)['entry'] as Map),
              },
          };
        }
      });
    }
  }

  Future<void> importCached() async {
    final incoming = await remote.entries();
    if (incoming.isEmpty) return;
    final schema = await remote.snapshot();
    await catalog.mutate((cards) async {
      final links = await bindings();
      for (final entry in incoming.values) {
        final remoteId = entry.item.id;
        var id = links.entries
            .where((e) => (e.value as Map)['remoteId'] == remoteId)
            .firstOrNull
            ?.key;
        id ??= cards.values
            .where(
              (e) =>
                  entry.sourceBookId != null &&
                  e.sourceBookId == entry.sourceBookId,
            )
            .firstOrNull
            ?.item
            .id;
        id ??= uuid.v5(Namespace.url.value, 'library:$namespace:$remoteId');
        final link = Map<String, dynamic>.from(links[id] as Map? ?? {});
        if (link['detached'] == true) continue;
        final base = Map<String, dynamic>.from(link['base'] as Map? ?? {});
        final collection = (schema?['collections'] as List? ?? [])
            .whereType<Map>()
            .where((c) => c['id'] == entry.item.collectionId)
            .firstOrNull;
        final values = personalValues(
          entry.state == 'conflict' ? entry.remote ?? entry.item : entry.item,
          collection: collection,
        );
        final waiting = entry.operation != null && entry.state != 'conflict';
        final old = cards[id];
        final merged = Map<String, dynamic>.from(
          old?.item.values ??
              personalValues(entry.item, collection: collection),
        );
        final conflicts = Map<String, dynamic>.from(
          link['conflicts'] as Map? ?? {},
        );
        final sent = link['sent'] as Map?;
        for (final field in values.entries) {
          if (waiting) continue;
          final current = merged[field.key];
          if (entry.state == 'conflict' &&
              !sameMetadataValue(current, field.value)) {
            conflicts[field.key] = field.value;
            continue;
          }
          if (entry.state == 'synced' &&
              sent != null &&
              sent.containsKey(field.key)) {
            if (sameMetadataValue(current, sent[field.key])) {
              merged[field.key] = field.value;
              conflicts.remove(field.key);
              continue;
            }
            if (sameMetadataValue(field.value, sent[field.key])) {
              conflicts.remove(field.key);
              continue;
            }
          }
          if (old == null ||
              sameMetadataValue(current, base[field.key]) ||
              (!base.containsKey(field.key) &&
                  (current == null || current == ''))) {
            merged[field.key] = field.value;
            conflicts.remove(field.key);
          } else if (sameMetadataValue(current, field.value)) {
            conflicts.remove(field.key);
          } else if (base.containsKey(field.key) &&
              !sameMetadataValue(base[field.key], field.value)) {
            conflicts[field.key] = field.value;
          }
        }
        // A deleted remote card remains a perfectly usable personal record.
        if (old == null ||
            !sameMetadataValue(old.item.values, merged) ||
            old.sourceBookId == null && entry.sourceBookId != null) {
          cards[id] = LibraryEntry(
            personalLibraryItem(
              id,
              entry.item.mediaType,
              merged,
              modifiedAt: entry.item.modifiedAt,
            ),
            sourceBookId: old?.sourceBookId ?? entry.sourceBookId,
          );
        }
        links[id] = {
          ...link,
          'remoteId': remoteId,
          'base': waiting
              ? (entry.remote == null
                    ? base
                    : personalValues(entry.remote!, collection: collection))
              : values,
          'sent': waiting ? sent : null,
          'conflicts': conflicts,
          'state': entry.state,
          'message': entry.message,
        };
        final policyKey = 'obsidian-policy:$personalLibraryNamespace:$id';
        if (await local.meta(policyKey) == null) {
          final policy = await local.meta(
            'obsidian-policy:$namespace:$remoteId',
          );
          if (policy != null) await local.setMeta(policyKey, policy);
        }
        final baselineKey = 'obsidian-auto:$personalLibraryNamespace:$id';
        if (await local.meta(baselineKey) == null) {
          final oldBaseline = await ReadingLibrary(local)
              .value('obsidian-auto:$namespace:$remoteId');
          if (oldBaseline.isNotEmpty) {
            await local.setMeta(
              baselineKey,
              jsonEncode(
                personalValues(
                  entry.item.withValues(oldBaseline),
                  collection: collection,
                ),
              ),
            );
          }
        }
      }
      await local.setMeta(key, jsonEncode(links));
    });
  }

  /// Map semantic local properties to the actual aliases of this connection.
  Map<String, dynamic> exportValues(
    LibraryItem item,
    List<LibraryField> fields,
    Map collection,
  ) {
    final values = <String, dynamic>{};
    for (final f in fields) {
      if (!item.values.containsKey(f.field)) continue;
      values[f.key] = switch (f.field) {
        'status' => exportLibraryStatus(item.value('status'), collection),
        'libraryType' => collection['id'],
        _ => item.value(f.field),
      };
    }
    if (item.value('unit') == 'characters' &&
        (collection['progressUnits'] as List? ?? []).contains('percent') &&
        item.value('total') is num &&
        (item.value('total') as num) > 0) {
      for (final f in fields) {
        if (f.field == 'unit') values[f.key] = 'percent';
        if (f.field == 'total') values[f.key] = 100;
        if (f.field == 'progress') {
          values[f.key] =
              ((item.value('progress') as num? ?? 0) /
                      (item.value('total') as num) *
                      10000)
                  .round() /
              100;
        }
      }
    }
    for (final entry in item.values.entries) {
      if (!personalLibraryFields.any((f) => f.key == entry.key) &&
          !fields.any((f) => f.key == entry.key) &&
          !entry.key.startsWith('pepehub_')) {
        values[entry.key] = entry.value;
      }
    }
    return values;
  }
}
