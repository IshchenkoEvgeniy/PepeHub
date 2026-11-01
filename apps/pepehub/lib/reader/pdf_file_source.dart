import 'package:flutter/services.dart';

import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import 'reading_roots.dart';

/// Keeps a seekable SAF descriptor alive for PDFium and the image-region worker.
/// Providers exposing only a stream retain the verified local-cache fallback.
class PdfFileSource {
  final String path;
  final String? _handle;
  bool _closed = false;
  PdfFileSource._(this.path, [this._handle]);
  bool get isDirect => _handle != null;

  static Future<PdfFileSource> open(
    LocalAsset asset,
    AssetStore assets, {
    bool preferDirect = true,
  }) async {
    if (!asset.path.startsWith('content:')) return PdfFileSource._(asset.path);
    if (!preferDirect) {
      return PdfFileSource._(
        (await ReadingRoots(assets).forReading(asset)).path,
      );
    }
    try {
      final descriptor = await audioFolderChannel
          .invokeMapMethod<String, dynamic>('openPdfDescriptor', {
            'uri': asset.path,
            'bytes': asset.bytes,
          });
      if (descriptor != null) {
        return PdfFileSource._(
          descriptor['path'] as String,
          descriptor['handle'] as String,
        );
      }
    } on MissingPluginException {
      // An older native host can still use its stream/copy implementation.
    } on PlatformException {
      // A non-seekable/cloud provider may only support a sequential stream.
    }
    return PdfFileSource._((await ReadingRoots(assets).forReading(asset)).path);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_handle != null) {
      try {
        await audioFolderChannel.invokeMethod<void>('closePdfDescriptor', {
          'handle': _handle,
        });
      } on MissingPluginException {
        // Native teardown already releases outstanding descriptors.
      } on PlatformException {
        // Native teardown already releases outstanding descriptors.
      }
    }
  }
}
