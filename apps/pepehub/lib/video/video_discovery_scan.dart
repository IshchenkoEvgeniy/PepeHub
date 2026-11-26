import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'video_discovery.dart';
import 'video_import.dart' show videoFilesChannel, videoExtensions;

class VideoDiscoveryCancelled implements Exception {
  @override
  String toString() => 'Поиск отменён';
}

class VideoScanResult {
  final List<VideoCandidate> files;

  /// Folders that could not be read, with the reason.
  final List<String> errors;
  const VideoScanResult(this.files, {this.errors = const []});
}

/// Finds videos without reading their contents. Replaceable in tests.
abstract class VideoDiscoveryScanner {
  /// Android's media index is available only on Android.
  bool get supportsDevice;

  Future<({String root, String title})?> pickRoot();

  Future<VideoScanResult> scan({
    required List<({String root, String title})> roots,
    required bool device,
    void Function(int found)? onProgress,
  });

  Future<void> cancel();
}

class PlatformVideoDiscoveryScanner implements VideoDiscoveryScanner {
  const PlatformVideoDiscoveryScanner();
  static bool _cancelled = false;
  static void Function(int found)? _progress;
  static bool _listening = false;

  @override
  bool get supportsDevice => Platform.isAndroid;

  @override
  Future<({String root, String title})?> pickRoot() async {
    if (Platform.isAndroid) {
      final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
        'pickTree',
      );
      if (result == null) return null;
      return (root: result['root'] as String, title: result['title'] as String);
    }
    final path = await getDirectoryPath();
    if (path == null) return null;
    final normal = p.normalize(p.absolute(path));
    return (root: normal, title: p.basename(normal));
  }

  @override
  Future<VideoScanResult> scan({
    required List<({String root, String title})> roots,
    required bool device,
    void Function(int found)? onProgress,
  }) async {
    _cancelled = false;
    if (Platform.isAndroid) {
      _progress = onProgress;
      if (!_listening) {
        _listening = true;
        // Only the search reports back on this channel.
        videoFilesChannel.setMethodCallHandler((call) async {
          if (call.method == 'discoveryProgress') {
            _progress?.call((call.arguments as num).toInt());
          }
        });
      }
      try {
        final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
          'discover',
          {
            'roots': [for (final root in roots) root.root],
            'device': device,
          },
        );
        if (result == null) throw VideoDiscoveryCancelled();
        return VideoScanResult(
          [
            for (final entry in result['files'] as List)
              VideoCandidate.fromJson(Map<String, dynamic>.from(entry as Map)),
          ],
          errors: [
            for (final error in result['errors'] as List? ?? const [])
              error.toString(),
          ],
        );
      } on PlatformException catch (e) {
        if (e.code == 'cancelled') throw VideoDiscoveryCancelled();
        rethrow;
      } finally {
        _progress = null;
      }
    }
    return _scanDesktop(roots, onProgress);
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    if (Platform.isAndroid) {
      await videoFilesChannel.invokeMethod<void>('cancelDiscovery');
    }
  }

  static Future<VideoScanResult> _scanDesktop(
    List<({String root, String title})> roots,
    void Function(int found)? onProgress,
  ) async {
    final files = <VideoCandidate>[];
    final errors = <String>[];
    var entries = 0;
    for (final root in roots) {
      final directory = Directory(root.root);
      Future<void> visit(Directory folder, String prefix, int depth) async {
        if (depth > 32) return;
        await for (final entry in folder.list(followLinks: false)) {
          if (_cancelled) throw VideoDiscoveryCancelled();
          if (++entries > 500000) {
            throw StateError('Слишком много файлов: больше 500000');
          }
          final name = p.basename(entry.path);
          if (entry is Directory) {
            if (!name.startsWith('.') &&
                name.toLowerCase() != r'$recycle.bin') {
              await visit(entry, '$prefix/$name', depth + 1);
            }
          } else if (entry is File &&
              videoExtensions.contains(
                p.extension(name).toLowerCase().replaceFirst('.', ''),
              )) {
            final stat = await entry.stat();
            files.add(
              VideoCandidate(
                source: entry.path,
                path: '$prefix/$name',
                size: stat.size,
                modifiedMs: stat.modified.millisecondsSinceEpoch,
              ),
            );
            if (files.length > 50000) {
              throw StateError('Найдено больше 50000 видео. Сузьте папки');
            }
            if (files.length % 200 == 0) onProgress?.call(files.length);
          }
        }
      }

      try {
        if (!await directory.exists()) throw StateError('папка не найдена');
        await visit(directory, root.title, 0);
      } on VideoDiscoveryCancelled {
        rethrow;
      } catch (e) {
        if (e is StateError && e.message.startsWith('Найдено больше')) {
          rethrow;
        }
        errors.add('${root.title}: $e');
      }
    }
    onProgress?.call(files.length);
    return VideoScanResult(files, errors: errors);
  }
}
