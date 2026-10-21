import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../audio/audio_import.dart' show naturalAudioOrder;
import 'video_repository.dart';
import 'models.dart';
import 'video_fingerprint.dart';
import 'media_formats.dart';

const videoFilesChannel = MethodChannel('app.pepehub/video_files');
const videoExtensions = [
  'mp4',
  'mkv',
  'webm',
  'mov',
  'm4v',
  'avi',
  'mpeg',
  'mpg',
];
const mediaExtensions = [...videoExtensions, ...musicExtensions];

class VideoImportSelection {
  final String title;
  final String? root;
  final List<VideoSourceDraft> sources;
  const VideoImportSelection(this.title, this.sources, {this.root});
}

typedef VideoFilePicker = Future<VideoImportSelection?> Function({bool folder});

VideoSourceDraft videoDraft(
  String source,
  String name, {
  VideoFileIdentity? identity,
  bool audio = false,
}) {
  final normalized = name.replaceAll('\\', '/');
  final folder = p.posix.dirname(normalized);
  return VideoSourceDraft(
    source,
    p.posix.basenameWithoutExtension(normalized),
    module: folder == '.' ? '' : folder,
    relativeName: normalized,
    identity: identity,
    audio: audio || isMusicSource(name),
  );
}

String validateVideoUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw ArgumentError('Введите прямую HTTP(S)-ссылку на видео или аудио');
  }
  return uri.toString();
}

Future<VideoImportSelection?> pickVideoFiles({bool folder = false}) async {
  if (Platform.isAndroid) {
    final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
      folder ? 'pickFolder' : 'pickFiles',
    );
    if (result == null) return null;
    final entries =
        List<Map<String, dynamic>>.from(
          (result['files'] as List).map(
            (entry) => Map<String, dynamic>.from(entry as Map),
          ),
        )..sort(
          (a, b) => naturalAudioOrder(a['name'] as String, b['name'] as String),
        );
    return VideoImportSelection(result['title'] as String, [
      for (final entry in entries)
        videoDraft(
          entry['uri'] as String,
          entry['name'] as String,
          audio: entry['audio'] == true,
          identity: entry['identity'] == null
              ? null
              : VideoFileIdentity.fromJson(
                  Map<String, dynamic>.from(entry['identity'] as Map),
                ),
        ),
    ], root: result['root'] as String?);
  }
  if (folder) {
    final path = await getDirectoryPath();
    return path == null ? null : scanVideoFolder(path);
  }
  final files = await openFiles(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'Медиа: видео и музыка',
        extensions: mediaExtensions,
      ),
    ],
  );
  if (files.isEmpty) return null;
  files.sort((a, b) => naturalAudioOrder(a.name, b.name));
  return VideoImportSelection(
    files.length == 1
        ? p.basenameWithoutExtension(files.single.name)
        : files.every((file) => isMusicSource(file.name))
        ? 'Новый плейлист'
        : 'Новая подборка',
    [for (final file in files) videoDraft(file.path, file.name)],
  );
}

Future<VideoImportSelection> scanVideoFolder(String path) async {
  if (Platform.isAndroid) {
    final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
      'scanFolder',
      {'root': path},
    );
    if (result == null) throw StateError('Папка недоступна');
    final entries =
        List<Map<String, dynamic>>.from(
          (result['files'] as List).map(
            (entry) => Map<String, dynamic>.from(entry as Map),
          ),
        )..sort(
          (a, b) => naturalAudioOrder(a['name'] as String, b['name'] as String),
        );
    return VideoImportSelection(result['title'] as String, [
      for (final entry in entries)
        videoDraft(
          entry['uri'] as String,
          entry['name'] as String,
          audio: entry['audio'] == true,
          identity: entry['identity'] == null
              ? null
              : VideoFileIdentity.fromJson(
                  Map<String, dynamic>.from(entry['identity'] as Map),
                ),
        ),
    ], root: path);
  }
  final root = Directory(p.normalize(p.absolute(path)));
  final sources = <({String path, String name})>[];
  var entries = 0;
  Future<void> visit(Directory directory, int depth) async {
    if (depth > 32) {
      throw StateError('Слишком много вложенных папок (максимум 32)');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (++entries > 50000) throw StateError('В папке больше 50000 элементов');
      if (entry is Directory) {
        if (p.basename(entry.path).toLowerCase() != '.pepehub') {
          await visit(entry, depth + 1);
        }
      } else if (entry is File &&
          mediaExtensions.contains(
            p.extension(entry.path).toLowerCase().replaceFirst('.', ''),
          )) {
        sources.add((
          path: entry.path,
          name: p.relative(entry.path, from: root.path).replaceAll('\\', '/'),
        ));
        if (sources.length > 10000) {
          throw StateError('В папке больше 10000 медиафайлов');
        }
      }
    }
  }

  await visit(root, 0);
  sources.sort((a, b) => naturalAudioOrder(a.name, b.name));
  final drafts = <VideoSourceDraft>[];
  for (final source in sources) {
    drafts.add(
      videoDraft(
        source.path,
        source.name,
        identity: await fingerprintVideoFile(source.path),
      ),
    );
  }
  return VideoImportSelection(p.basename(root.path), drafts, root: root.path);
}

Future<void> verifyVideoSources(Iterable<VideoSourceDraft> sources) async {
  final known = sources.where((source) => source.identity != null).toList();
  if (known.isEmpty) return;
  if (Platform.isAndroid) {
    final result = await videoFilesChannel.invokeMethod<bool>('verifyFiles', {
      'files': [
        for (final source in known)
          {'uri': source.source, 'identity': source.identity!.toJson()},
      ],
    });
    if (result != true) {
      throw StateError('Файлы изменились после проверки. Обновите папку курса');
    }
    return;
  }
  for (final source in known) {
    final current = await fingerprintVideoFile(source.source),
        expected = source.identity!;
    if (!current.sameSample(expected) ||
        current.modifiedMs != expected.modifiedMs) {
      throw StateError(
        'Файл изменился: ${source.relativeName ?? source.title}. Обновите папку курса',
      );
    }
  }
}
