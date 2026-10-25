import 'dart:convert';

import 'app_sync_codec.dart';
import 'app_sync_media.dart';
import 'app_sync_models.dart';
import 'app_sync_store.dart';
import 'peer_models.dart';
import 'peer_store.dart';

class AppSyncIssue {
  final String key, target;
  final List<AppSyncVersion> versions;
  final bool protected, pending;
  const AppSyncIssue(
    this.key,
    this.target,
    this.versions, {
    required this.protected,
    required this.pending,
  });
}

class AppSyncEngine {
  final AppSyncStore store;
  final AppSyncCodec codec;
  final String device;
  List<String> get validationWarnings {
    final problems = codec.localProblems.values.toList();
    return [
      ...problems.take(99).map((p) => p.warning),
      if (problems.length > 99)
        'Ещё ${problems.length - 99} локальных записей требуют проверки. Откройте «Спорные и ожидающие данные».',
    ];
  }

  Future<void>? _initializing;
  Future<void> _work = Future.value();
  Future<T> _serialize<T>(Future<T> Function() action) {
    final next = _work.then((_) => action());
    _work = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  AppSyncEngine(
    PeerStore peer,
    this.device,
    AppSyncMedia media, {
    bool Function(String)? isProtected,
  }) : store = media.store,
       codec = AppSyncCodec(media, isProtected: isProtected);
  Future<void> initialize() => _initializing ??= store.initialize();
  Future<void> refresh() => _serialize(_refreshPrepared);
  Future<void> _refreshPrepared() async {
    await initialize();
    await codec.media.prepare();
    await codec.media.prepareNames();
    codec.media.checkAmbiguousBindings();
    await store.db.transaction(_refresh);
  }

  Future<void> _refresh() async {
    final snapshot = await codec.snapshot(),
        projections = await store.projections();
    for (final local in snapshot.values) {
      final old = projections[local.key];
      if (old?.digest == local.digest) continue;
      final version = AppSyncVersion(local.key, local.value, {
        ...?old?.clock,
        device: await store.peer.nextCounter(),
      });
      codec.validate(version);
      await store.merge(version);
      await store.project(
        AppSyncProjection(
          local.key,
          local.target,
          local.digest,
          version.clock,
          true,
        ),
      );
    }
    for (final old in projections.values) {
      if (!old.materialized ||
          codec.localProblems.containsKey(old.target) ||
          snapshot.containsKey(old.key) ||
          old.digest == appSyncDigest(null) ||
          await codec.exists(old.target)) {
        continue;
      }
      final version = AppSyncVersion(old.key, null, {
        ...old.clock,
        device: await store.peer.nextCounter(),
      });
      codec.validate(version);
      await store.merge(version);
      await store.project(
        AppSyncProjection(
          old.key,
          old.target,
          version.content,
          version.clock,
          true,
        ),
      );
    }
  }

  Future<List<Map<String, dynamic>>> manifest({
    String after = '',
    int limit = 128,
  }) async {
    await initialize();
    if (limit < 1 ||
        limit > 128 ||
        after.isNotEmpty && !appSyncHash.hasMatch(after)) {
      throw const FormatException('Неверная страница индекса');
    }
    return store.manifestPage(after, limit);
  }

  Future<List<int>> read(String id, int offset, int count) async {
    if (!appSyncHash.hasMatch(id) ||
        offset < 0 ||
        count < 1 ||
        count > peerChunkSize) {
      throw const FormatException('Неверный блок данных');
    }
    final version = await store.version(id);
    if (version == null) throw StateError('Версия данных больше недоступна');
    final bytes = version.bytes;
    if (offset > bytes.length) throw const FormatException('Неверное смещение');
    return bytes.sublist(offset, (offset + count).clamp(0, bytes.length));
  }

  Future<void> receive(
    Map<String, dynamic> header,
    Future<List<int>> Function(int offset, int count) read,
  ) async {
    final id = header['id'], key = header['key'], length = header['bytes'];
    if (id is! String ||
        !appSyncHash.hasMatch(id) ||
        key is! String ||
        !codec.supported(key) ||
        length is! int ||
        length < 1 ||
        length > appSyncMaxBytes) {
      throw const FormatException('Некорректный заголовок данных');
    }
    if (await store.version(id) != null) return;
    final bytes = <int>[];
    while (bytes.length < length) {
      final count = (length - bytes.length).clamp(1, peerChunkSize),
          chunk = await read(
            bytes.length,
            (length - bytes.length).clamp(1, peerChunkSize),
          );
      if (chunk.isEmpty || chunk.length > count) {
        throw StateError('Получен некорректный блок');
      }
      bytes.addAll(chunk);
    }
    if (peerDigest(bytes) != id) {
      throw StateError('Контрольная сумма данных не совпала');
    }
    late final AppSyncVersion version;
    try {
      version = AppSyncVersion.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      if (version.id != id || version.key != key) {
        throw const FormatException('Версия не соответствует заголовку');
      }
      codec.validate(version);
    } on FormatException catch (failure) {
      throw AppSyncRejectedRecord(key, failure.message);
    } on TypeError {
      throw AppSyncRejectedRecord(key, 'Неверный тип поля записи');
    } on ArgumentError {
      throw AppSyncRejectedRecord(key, 'Недопустимое значение поля записи');
    }
    await store.db.transaction(() async {
      if ((await store.heads(key)).length >= 64) {
        throw StateError('Слишком много спорных версий');
      }
      await store.merge(version);
    });
  }

  Future<int> applyPending({void Function()? ensureAllowed}) =>
      _serialize(() => _applyPending(ensureAllowed));
  Future<int> _applyPending(void Function()? ensureAllowed) async {
    await initialize();
    ensureAllowed?.call();
    var count = 0;
    await store.db.transaction(() async {
      // Capture edits made during network IO before projecting any received state.
      await _refresh();
      final groups = <String, List<AppSyncVersion>>{};
      for (final version in await store.heads()) {
        (groups[version.key] ??= []).add(version);
      }
      final keys = groups.keys.toList()
        ..sort((a, b) {
          int priority(String key) => key.startsWith('media:book:')
              ? 0
              : key.startsWith('media:item:')
              ? 1
              : key.startsWith('media:lesson:')
              ? 2
              : key.startsWith('record:book:')
              ? 3
              : 4;
          final order = priority(a).compareTo(priority(b));
          return order != 0 ? order : a.compareTo(b);
        });
      final applied = <AppSyncVersion>[];
      final projections = await store.projections();
      final snapshot = await codec.snapshot();
      for (final key in keys) {
        ensureAllowed?.call();
        var heads = groups[key]!;
        if (heads.length > 1 &&
            (heads.every((v) => v.content == heads.first.content) ||
                key.startsWith('meta:reading-coverage:') &&
                    heads.every((v) => !v.deleted))) {
          final clock = heads.fold(
            <String, int>{},
            (a, v) => mergePeerClocks(a, v.clock),
          );
          final joined = AppSyncVersion(
            key,
            key.startsWith('meta:reading-coverage:')
                ? AppSyncCodec.mergeCoverage(heads)
                : heads.first.value,
            clock,
          );
          await store.merge(joined);
          heads = [joined];
        }
        if (heads.length != 1) continue;
        final desired = heads.single,
            old = projections[key],
            local = snapshot[key];
        if (old?.materialized == true &&
            appSyncJson(old!.clock) == appSyncJson(desired.clock) &&
            !await codec.needsRepair(key)) {
          continue;
        }
        if (codec.blocked(codec.target(key))) continue;
        if (local?.digest == desired.content && !key.startsWith('media:')) {
          applied.add(desired);
          continue;
        }
        if (await codec.apply(desired)) {
          applied.add(desired);
          count++;
        }
      }
      final after = await codec.snapshot();
      ensureAllowed?.call();
      for (final version in applied) {
        final local = after[version.key];
        await store.project(
          AppSyncProjection(
            version.key,
            local?.target ?? codec.target(version.key),
            local?.digest ?? version.content,
            version.clock,
            true,
          ),
        );
      }
    });
    if (count > 0) store.peer.repository.notifyExternalChange();
    return count;
  }

  Future<List<AppSyncIssue>> issues() async {
    final groups = <String, List<AppSyncVersion>>{};
    for (final version in await store.heads()) {
      (groups[version.key] ??= []).add(version);
    }
    final projections = await store.projections();
    return [
      for (final entry in groups.entries)
        if (entry.value.length > 1 ||
            projections[entry.key] == null ||
            appSyncJson(projections[entry.key]!.clock) !=
                appSyncJson(entry.value.single.clock))
          AppSyncIssue(
            entry.key,
            codec.target(entry.key),
            entry.value,
            protected: codec.blocked(codec.target(entry.key)),
            pending: entry.value.length == 1,
          ),
    ];
  }

  Future<void> resolve(String key, String selected, Set<String> expected) =>
      _serialize(() => _resolve(key, selected, expected));
  Future<void> _resolve(
    String key,
    String selected,
    Set<String> expected,
  ) async {
    await store.db.transaction(() async {
      await _refresh();
      final heads = await store.heads(key);
      if (appSyncJson(heads.map((v) => v.id).toList()..sort()) !=
          appSyncJson(expected.toList()..sort())) {
        throw StateError('Данные изменились. Откройте список заново');
      }
      if (codec.blocked(codec.target(key))) {
        if (codec.localProblems.containsKey(codec.target(key))) {
          throw StateError(
            'Локальная запись требует исправления. Исходные данные сохранены; подробности в списке проблем.',
          );
        }
        throw StateError('Сначала закройте книгу или остановите плеер');
      }
      final chosen = heads.firstWhere((v) => v.id == selected);
      final clock = heads.fold(
        <String, int>{},
        (a, v) => mergePeerClocks(a, v.clock),
      );
      final next = AppSyncVersion(key, chosen.value, {
        ...clock,
        device: await store.peer.nextCounter(),
      });
      if (!await codec.apply(next)) {
        throw StateError('Источник недоступен или имеет другую версию');
      }
      await store.merge(next);
      final local = (await codec.snapshot())[key];
      await store.project(
        AppSyncProjection(
          key,
          local?.target ?? codec.target(key),
          local?.digest ?? next.content,
          next.clock,
          true,
        ),
      );
    });
    store.peer.repository.notifyExternalChange();
  }
}
