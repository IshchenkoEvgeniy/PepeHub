import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class _BoundedSink implements Sink<List<int>> {
  final int limit;
  final bytes = BytesBuilder(copy: false);
  _BoundedSink(this.limit);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('Превышен лимит распаковки');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

/// Reads selected entries only; no archive paths are written to disk.
class BookArchive {
  final entries = <String, ZipFileHeader>{};
  var decoded = 0;
  BookArchive(Uint8List bytes) {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 5000) {
      throw const FormatException('Некорректный или слишком большой ZIP');
    }
    var total = 0;
    for (final entry in directory.fileHeaders) {
      final name = entry.filename;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').contains('..') ||
          entries.containsKey(name) ||
          (entry.generalPurposeBitFlag & 1) != 0 ||
          ![0, 8].contains(entry.compressionMethod)) {
        throw const FormatException('Неподдерживаемая структура ZIP');
      }
      total += entry.uncompressedSize;
      if (total > 256 * 1024 * 1024) {
        throw const FormatException('ZIP превышает лимит распаковки');
      }
      entries[name] = entry;
    }
  }
  Uint8List read(String name, {int limit = 16 * 1024 * 1024}) {
    final entry = entries[name];
    if (entry == null || entry.file == null || entry.uncompressedSize > limit) {
      throw FormatException('Нет раздела $name или превышен лимит');
    }
    final output = _BoundedSink(limit);
    final input = InputMemoryStream(entry.file!.getRawContent());
    if (entry.compressionMethod == 8) {
      final sink = ZLibCodec(raw: true).decoder.startChunkedConversion(output);
      while (!input.isEOS) {
        sink.add(input.readBytes(input.length.clamp(0, 8192)).toUint8List());
      }
      sink.close();
    } else {
      output.add(input.toUint8List());
    }
    final bytes = output.bytes.takeBytes();
    decoded += bytes.length;
    if (decoded > 32 * 1024 * 1024 ||
        bytes.length != entry.uncompressedSize ||
        getCrc32(bytes) != entry.crc32) {
      throw const FormatException('Повреждённый или слишком большой ZIP');
    }
    return bytes;
  }
}
