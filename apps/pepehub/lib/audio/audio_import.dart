import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../media/verified_stream_copy.dart';
import '../reader/book_formats.dart';
import 'audio_folder.dart';

final _naturalPattern = RegExp(r'\d+|\D+');
Future<String> _hashLocalAudio(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);
final _naturalKeys = <String, List<({String text, BigInt? number})>>{};
List<({String text, BigInt? number})> _naturalKey(String value) {
  final key = value.toLowerCase();
  final cached = _naturalKeys[key];
  if (cached != null) return cached;
  final result = [
    for (final m in _naturalPattern.allMatches(key))
      (text: m[0]!, number: BigInt.tryParse(m[0]!)),
  ];
  if (_naturalKeys.length >= 8192) _naturalKeys.remove(_naturalKeys.keys.first);
  _naturalKeys[key] = result;
  return result;
}

int naturalAudioOrder(String a, String b) {
  final left = _naturalKey(a), right = _naturalKey(b);
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = left[i], y = right[i];
    final order = x.number != null && y.number != null
        ? x.number!.compareTo(y.number!)
        : x.text.compareTo(y.text);
    if (order != 0) return order;
  }
  final order = left.length.compareTo(right.length);
  return order != 0 ? order : a.compareTo(b);
}

class ImportCancelled implements Exception {
  @override
  String toString() => 'Импорт отменён';
}

class AudioImportControl {
  bool cancelled = false;
  void check() {
    if (cancelled) throw ImportCancelled();
  }
}

bool validAudioHeader(String extension, List<int> bytes) {
  if (bytes.length < 12) return false;
  final text = String.fromCharCodes(bytes);
  return switch (extension) {
    '.mp3' =>
      text.startsWith('ID3') || (bytes[0] == 255 && (bytes[1] & 224) == 224),
    '.m4b' || '.m4a' => text.substring(4, 8) == 'ftyp',
    '.aac' => bytes[0] == 255 && (bytes[1] & 246) == 240,
    '.ogg' || '.opus' => text.startsWith('OggS'),
    '.flac' => text.startsWith('fLaC'),
    '.wav' => text.startsWith('RIFF') && text.substring(8, 12) == 'WAVE',
    _ => false,
  };
}

class _StagedAudio {
  final String name, hash, extension;
  final int bytes;
  final File file;
  String? target;
  _StagedAudio(this.name, this.hash, this.extension, this.bytes, this.file);
}

/// No book is published until every selected file has been copied and checked.
/// Input order is the user-confirmed order; sorting belongs to the preview.
class AudioImportService {
  final Repository repository;
  final Directory directory;
  bool _running = false;
  AudioImportService(this.repository, this.directory);

  Future<String> importBook(
    List<XFile> files, {
    required String title,
    AudioImportControl? control,
    void Function(int done, int total)? onProgress,
    int maxFileBytes = 8 * 1024 * 1024 * 1024,
  }) async {
    if (_running) throw StateError('Дождитесь завершения импорта');
    if (files.isEmpty || files.length > 1000) {
      throw ArgumentError('Выберите от 1 до 1000 аудиофайлов');
    }
    final cleanTitle = title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    if (cleanTitle.isEmpty || cleanTitle.length > 500) {
      throw ArgumentError('Название: от 1 до 500 символов');
    }
    _running = true;
    Directory? staging;
    final published = <File>[];
    try {
      control?.check();
      final sizes = <int>[];
      for (final file in files) {
        if (!audioExtensions.contains(
          p.extension(file.name).toLowerCase().replaceFirst('.', ''),
        )) {
          throw ArgumentError('Не поддерживается: ${file.name}');
        }
        final size = await file.length();
        if (size < 12 || size > maxFileBytes) {
          throw ArgumentError('Недопустимый размер: ${file.name}');
        }
        sizes.add(size);
      }
      final total = sizes.fold<int>(0, (a, b) => a + b);
      await directory.create(recursive: true);
      staging = await Directory(p.join(directory.path, '.imports', uuid.v4()))
          .create(recursive: true);
      final staged = <_StagedAudio>[];
      var copied = 0, lastReport = -100, reported = -1;
      final progressClock = Stopwatch()..start();
      void report(int done) {
        if (done != reported &&
            (progressClock.elapsedMilliseconds - lastReport >= 100 ||
                done == total)) {
          lastReport = progressClock.elapsedMilliseconds;
          reported = done;
          onProgress?.call(done, total);
        }
      }

      for (var index = 0; index < files.length; index++) {
        final selected = files[index];
        final temporary = File(p.join(staging.path, '$index.part'));
        final copiedFile = await copyVerifiedStream(
          selected.openRead(),
          temporary,
          expectedBytes: sizes[index],
          check: control?.check,
          onProgress: (count) => report(copied + count),
        );
        final count = copiedFile.bytes, header = copiedFile.header;
        copied += count;
        final extension = p.extension(selected.name).toLowerCase();
        if (count != sizes[index] || !validAudioHeader(extension, header)) {
          throw ArgumentError(
            'Размер или содержимое не соответствует аудиоформату: ${selected.name}',
          );
        }
        staged.add(
          _StagedAudio(
            selected is FolderAudioFile
                ? selected.name
                : p.basename(selected.name),
            copiedFile.hash,
            extension,
            count,
            temporary,
          ),
        );
      }
      control?.check();
      // Resolve an existing physical resource before publishing any new card.
      final targetsByHash = <String, String>{};
      for (final entry in staged) {
        control?.check();
        final alreadyPrepared = targetsByHash[entry.hash];
        if (alreadyPrepared != null) {
          entry.target = alreadyPrepared;
          continue;
        }
        final resource = await repository.db
            .customSelect(
              'SELECT path FROM audio_resources WHERE sha256=?',
              variables: [Variable(entry.hash)],
            )
            .getSingleOrNull();
        final target = File(
          resource?.read<String>('path') ??
              p.join(directory.path, '${entry.hash}${entry.extension}'),
        );
        if (await target.exists()) {
          if (await target.length() != entry.bytes) {
            throw StateError('Повреждена локальная копия: ${entry.name}');
          }
          final targetPath = target.path;
          final actual = await _hashLocalAudio(targetPath);
          control?.check();
          if (actual != entry.hash) {
            throw StateError('Повреждена локальная копия: ${entry.name}');
          }
        } else {
          await target.parent.create(recursive: true);
          await entry.file.rename(target.path);
          published.add(target);
        }
        entry.target = target.path;
        targetsByHash[entry.hash] = target.path;
      }
      control?.check();
      return await repository.db.transaction(() async {
        control?.check();
        // Match the complete ordered manifest, never only one shared track.
        final candidates = await repository.db
            .customSelect(
              'SELECT e.id,e.book_id FROM audio_editions e JOIN audio_tracks t ON t.edition_id=e.id WHERE t.ordinal=0 AND t.asset_hash=?',
              variables: [Variable(staged.first.hash)],
            )
            .get();
        for (final candidate in candidates) {
          final tracks = await repository.db
              .customSelect(
                'SELECT asset_hash FROM audio_tracks WHERE edition_id=? ORDER BY ordinal',
                variables: [Variable(candidate.read<String>('id'))],
              )
              .get();
          if (jsonEncode(
                tracks.map((r) => r.read<String>('asset_hash')).toList(),
              ) ==
              jsonEncode(staged.map((e) => e.hash).toList())) {
            final id = candidate.read<String>('book_id');
            if ((await repository.record(id))?.deleted != false) {
              throw StateError(
                'Эта книга удалена. Автоматическое восстановление отключено.',
              );
            }
            return id;
          }
        }
        final bookId = uuid.v4(), editionId = uuid.v4();
        await repository.put('book', bookId, {
          'title': cleanTitle,
          'authors': <String>[],
          'format': 'audio',
          'status': 'planned',
        });
        await repository.db.customStatement(
          'INSERT INTO audio_editions VALUES(?,?,1)',
          [editionId, bookId],
        );
        for (var i = 0; i < staged.length; i++) {
          control?.check();
          final entry = staged[i];
          await repository.db.customStatement(
            'INSERT OR IGNORE INTO audio_resources VALUES(?,?,?)',
            [entry.hash, entry.target!, entry.bytes],
          );
          await repository.db.customStatement(
            'INSERT INTO audio_tracks VALUES(?,?,?,?,?,NULL)',
            [uuid.v4(), editionId, entry.hash, i, entry.name],
          );
        }
        control?.check();
        return bookId;
      });
    } catch (_) {
      // Delete only files this import created and no committed record owns.
      for (final file in published) {
        final owner = await repository.db
            .customSelect(
              'SELECT sha256 FROM audio_resources WHERE path=?',
              variables: [Variable(file.path)],
            )
            .get();
        if (owner.isEmpty && await file.exists()) await file.delete();
      }
      rethrow;
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      final parent = Directory(p.join(directory.path, '.imports'));
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
      _running = false;
    }
  }
}
