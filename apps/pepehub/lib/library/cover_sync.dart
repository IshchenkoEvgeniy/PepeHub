import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../media/audio_artwork.dart';
import '../reader/reading_library.dart';
import 'library_repository.dart';
import 'models.dart';
import 'obsidian_sync_service.dart';

class CoverSync {
  final AssetStore assets;
  final http.Client client;
  final ObsidianConfig? config;
  CoverSync(this.assets, this.client, this.config);
  CoverSync.local(this.assets, this.client) : config = null;
  Repository get local => assets.repository;
  String path(String hash) => p.join(
    assets.directory.path,
    'obsidian-covers',
    config?.namespace ?? 'personal',
    '$hash.png',
  );
  static String? referenceHash(dynamic value) =>
      value is String && RegExp(r'^pepehub-cover:[a-f0-9]{64}$').hasMatch(value)
      ? value.substring(14)
      : null;
  static bool validPng(Uint8List bytes) =>
      bytes.length >= 24 &&
      bytes.length <= 2097152 &&
      [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ].asMap().entries.every((e) => bytes[e.key] == e.value) &&
      ByteData.sublistView(bytes).getUint32(16) > 0 &&
      ByteData.sublistView(bytes).getUint32(16) <= 2048 &&
      ByteData.sublistView(bytes).getUint32(20) > 0 &&
      ByteData.sublistView(bytes).getUint32(20) <= 2048;
  Future<http.Response> request(
    String method,
    String hash, [
    Uint8List? body,
  ]) async {
    final config = this.config;
    if (config == null) {
      throw StateError('Подключите Obsidian для обмена обложками.');
    }
    final request =
        http.Request(
            method,
            Uri.parse('${config.url}/api/pepehub/library/covers/$hash'),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer ${config.token}';
    if (body != null) {
      request.headers['Content-Type'] = 'image/png';
      request.bodyBytes = body;
    }
    final response = await client
            .send(request)
            .timeout(const Duration(seconds: 20)),
        builder = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(
      const Duration(seconds: 20),
    )) {
      builder.add(part);
      if (builder.length > 2097152) throw StateError('Обложка превышает 2 МиБ');
    }
    return http.Response.bytes(
      builder.takeBytes(),
      response.statusCode,
      headers: response.headers,
    );
  }

  Future<Uint8List> normalize(Uint8List bytes) async {
    if (bytes.length > 16777216) {
      throw StateError('Исходная обложка превышает 16 МиБ');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes),
        descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 40000000) {
        throw StateError('Слишком большое изображение');
      }
      final scale =
          (640 /
                  (descriptor.width > descriptor.height
                      ? descriptor.width
                      : descriptor.height))
              .clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 640),
        targetHeight: (descriptor.height * scale).round().clamp(1, 640),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('Изображение не прочитано');
          final result = data.buffer.asUint8List();
          if (!validPng(result)) {
            throw StateError('Обложка превышает поддерживаемый размер');
          }
          return result;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<String> upload(Uint8List original) async {
    final bytes = await normalize(original),
        hash = sha256.convert(bytes).toString();
    if (config != null && (await request('HEAD', hash)).statusCode != 200) {
      final response = await request('POST', hash, bytes);
      if (response.statusCode != 200) {
        throw StateError(
          'Не удалось отправить обложку: HTTP ${response.statusCode}',
        );
      }
    }
    await _cache(hash, bytes);
    return hash;
  }

  Future<void> publishCached(String hash, String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    if (!validPng(bytes) || sha256.convert(bytes).toString() != hash) {
      throw StateError('Не удалось прочитать сохранённую обложку.');
    }
    if ((await request('HEAD', hash)).statusCode != 200) {
      final response = await request('POST', hash, bytes);
      if (response.statusCode != 200) {
        throw StateError(
          'Не удалось отправить обложку: HTTP ${response.statusCode}',
        );
      }
    }
    await _cache(hash, bytes);
  }

  Future<String?> choose() async {
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Обложка',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    if (selected == null) return null;
    if (await selected.length() > 16777216) {
      throw StateError('Обложка превышает 16 МиБ');
    }
    return 'pepehub-cover:${await upload(await selected.readAsBytes())}';
  }

  Future<void> _cache(String hash, Uint8List bytes) async {
    final file = File(path(hash));
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }

  Future<String> download(String hash) async {
    final file = File(path(hash));
    if (await file.exists() &&
        await file.length() <= 2097152 &&
        sha256.convert(await file.readAsBytes()).toString() == hash) {
      return file.path;
    }
    final response = await request('GET', hash);
    if (response.statusCode != 200 ||
        !validPng(response.bodyBytes) ||
        sha256.convert(response.bodyBytes).toString() != hash) {
      throw StateError(
        'Не удалось проверить обложку: HTTP ${response.statusCode}',
      );
    }
    await _cache(hash, response.bodyBytes);
    return file.path;
  }

  Future<String?> _native(LibraryEntry entry) async {
    final book = await local.record(entry.sourceBookId!);
    if (book == null || book.deleted) return null;
    if (book.payload?['format'] == 'audio') {
      if (await local.meta('audio-cover-hidden:${book.id}') == 'true') {
        return null;
      }
      final uri = await ArtworkStore(assets).load(book.id);
      return uri?.scheme == 'file'
          ? File.fromUri(uri!).path
          : await local.meta('audio-cover:${book.id}');
    }
    final row = await local.db
        .customSelect(
          'SELECT sha256 FROM local_assets WHERE book_id=? LIMIT 1',
          variables: [Variable(book.id)],
        )
        .getSingleOrNull();
    return (await ReadingLibrary(local)
            .bookInfo(book, row?.read<String>('sha256')))['cover']
        as String?;
  }

  Future<void> _setReaderCover(String id, String? path) async {
    final library = ReadingLibrary(local),
        prefs = await ReadingLibrary(local).value('reading-book:$id');
    await library.update('reading-book:$id', {
      'overrides': {
        ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
        'cover': path,
      },
    });
  }

  /// Returns true only when a new durable metadata operation was queued.
  Future<bool> run() async {
    final config = this.config;
    if (config == null) return false;
    final repo = LibraryRepository(local, config.namespace),
        stateKey = 'obsidian-cover-state:${config.namespace}';
    final state =
        jsonDecode(await local.meta(stateKey) ?? '{}') as Map<String, dynamic>;
    var queued = false;
    final errors = <String>[];
    for (final entry in (await repo.entries()).values) {
      try {
        if (entry.state == 'removed') continue;
        final remoteHash = entry.item.coverAsset?['hash'] as String?,
            remoteValue = entry.item.value('cover');
        String? remotePath;
        if (remoteHash != null) remotePath = await download(remoteHash);
        if (entry.sourceBookId == null) continue;
        final native = await _native(entry),
            file = native == null ? null : File(native);
        if (file != null && !await file.exists()) {
          throw StateError(
            'Локальный файл обложки недоступен; обложка Obsidian сохранена.',
          );
        }
        if (file != null && await file.length() > 16777216) {
          throw StateError(
            'Локальная обложка превышает 16 МиБ; обложка Obsidian сохранена.',
          );
        }
        final raw = file == null ? null : await file.readAsBytes();
        final localHash = raw == null ? null : sha256.convert(raw).toString(),
            previous = state[entry.item.id] as Map?;
        final localChanged =
            previous != null && previous['localHash'] != localHash;
        if (entry.state == 'synced' &&
            ((raw != null &&
                    previous == null &&
                    (remoteValue == null || '$remoteValue'.isEmpty)) ||
                localChanged)) {
          final hash = raw == null ? null : await upload(raw),
              nextValue = hash == null ? null : 'pepehub-cover:$hash',
              coverKey = entry.item.fields
                  .where((f) => f.field == 'cover')
                  .firstOrNull
                  ?.key;
          if (coverKey != null) {
            await repo.mutate((entries) async {
              final live = entries[entry.item.id];
              if (live?.state != 'synced') return;
              entries[entry.item.id] = LibraryEntry(
                live!.item.withValues({
                  ...live.item.values,
                  coverKey: nextValue,
                }),
                sourceBookId: live.sourceBookId,
                state: 'pending',
                operation: {
                  'operationId': uuid.v4(),
                  'itemId': live.item.id,
                  'action': 'update',
                  'collectionId': live.item.collectionId,
                  'mediaType': live.item.mediaType,
                  'base': {
                    coverKey: previous == null
                        ? remoteValue
                        : previous['remoteValue'],
                  },
                  'values': {coverKey: nextValue},
                },
              );
              queued = true;
            });
          }
        } else if (entry.state == 'synced' &&
            remotePath != null &&
            !localChanged &&
            (previous == null ||
                previous['remoteHash'] != remoteHash ||
                native == null)) {
          final book = await local.record(entry.sourceBookId!);
          if (book?.payload?['format'] == 'audio') {
            await local.setMeta('audio-cover-hidden:${book!.id}', 'false');
            await local.setMeta('audio-cover:${book.id}', remotePath);
          } else if (book != null) {
            await _setReaderCover(book.id, remotePath);
          }
        }
        if (entry.state == 'synced' &&
            !localChanged &&
            previous?['remoteHash'] != null &&
            remoteHash == null &&
            (remoteValue == null || '$remoteValue'.isEmpty)) {
          final book = await local.record(entry.sourceBookId!);
          if (book?.payload?['format'] == 'audio') {
            await local.setMeta('audio-cover-hidden:${book!.id}', 'true');
          } else if (book != null) {
            await _setReaderCover(book.id, null);
          }
        }
        final nextPath = await _native(entry),
            nextFile = nextPath == null ? null : File(nextPath);
        if (nextFile != null && await nextFile.length() > 16777216) {
          throw StateError('Локальная обложка превышает 16 МиБ.');
        }
        final nextHash = nextFile == null
            ? null
            : sha256.convert(await nextFile.readAsBytes()).toString();
        if (entry.state == 'synced') {
          state[entry.item.id] = {
            'localHash': nextHash,
            'remoteHash': remoteHash,
            'remoteValue': remoteValue,
          };
        }
        await local.setMeta(stateKey, jsonEncode(state));
      } catch (e) {
        errors.add('Обложка ${entry.item.title}: $e');
      }
    }
    await local.setMeta(
      'obsidian-cover-errors:${config.namespace}',
      errors.join('\n'),
    );
    return queued;
  }
}
