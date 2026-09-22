import 'dart:io';
import 'dart:typed_data';

// Reads metadata only; large mdat/audio payloads are skipped with seek.
Future<Uint8List?> embeddedArtwork(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    if (length < 10) return null;
    final header = await file.read(10);
    int sync(List<int> b) => b.fold(0, (v, n) => (v << 7) | (n & 127));
    int be(List<int> b) => b.fold(0, (v, n) => (v << 8) | n);
    if (String.fromCharCodes(header.take(3)) == 'ID3') {
      final version = header[3];
      // Extended headers, unsynchronisation and compressed frames are not guessed.
      if (![3, 4].contains(version) || header[5] != 0) return null;
      final size = sync(header.sublist(6, 10));
      if (size > 16 * 1024 * 1024 || size + 10 > length) return null;
      final bytes = await file.read(size);
      var offset = 0;
      while (offset + 10 <= bytes.length) {
        final name = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        final count = version == 4
            ? sync(bytes.sublist(offset + 4, offset + 8))
            : be(bytes.sublist(offset + 4, offset + 8));
        if (count <= 0 || offset + 10 + count > bytes.length) break;
        if (name == 'APIC' &&
            bytes[offset + 8] == 0 &&
            bytes[offset + 9] == 0) {
          final body = bytes.sublist(offset + 10, offset + 10 + count);
          if (body.isEmpty) return null;
          final mimeEnd = body.indexOf(0, 1);
          if (mimeEnd < 0 || mimeEnd + 2 >= body.length) return null;
          var start = mimeEnd + 2;
          final wide = body[0] == 1 || body[0] == 2;
          if (wide) {
            while (start + 1 < body.length &&
                !(body[start] == 0 && body[start + 1] == 0)) {
              start += 2;
            }
            start += 2;
          } else {
            start = body.indexOf(0, start);
            if (start < 0) return null;
            start++;
          }
          return start < body.length
              ? Uint8List.fromList(body.sublist(start))
              : null;
        }
        offset += 10 + count;
      }
      return null;
    }
    var nodes = 0;
    Future<Uint8List?> atoms(int start, int end, int depth, bool cover) async {
      if (depth > 8) return null;
      while (start + 8 <= end && nodes++ < 10000) {
        await file.setPosition(start);
        final h = await file.read(8);
        if (h.length != 8) return null;
        var size = be(h.sublist(0, 4)), head = 8;
        final type = String.fromCharCodes(h.sublist(4));
        if (size == 1) {
          final ext = await file.read(8);
          if (ext.length != 8) return null;
          size = be(ext);
          head = 16;
        }
        if (size == 0) size = end - start;
        if (size < head || size > end - start) return null;
        if (cover &&
            type == 'data' &&
            size - head > 8 &&
            size - head <= 16 * 1024 * 1024) {
          await file.setPosition(start + head + 8);
          return file.read(size - head - 8);
        }
        if (['moov', 'udta', 'meta', 'ilst', 'covr'].contains(type)) {
          final value = await atoms(
            start + head + (type == 'meta' ? 4 : 0),
            start + size,
            depth + 1,
            type == 'covr',
          );
          if (value != null) return value;
        }
        start += size;
      }
      return null;
    }

    return await atoms(0, length, 0, false);
  } finally {
    await file.close();
  }
}
