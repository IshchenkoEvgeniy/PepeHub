import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'audio_folder.dart';

class BookChapter {
  final String title;
  final int startMs;
  BookChapter(this.title, this.startMs);
}

class _Box {
  final String type;
  final Uint8List data;
  _Box(this.type, this.data);
}

int _u32(Uint8List b, int at) => ByteData.sublistView(b).getUint32(at);
int _u64(Uint8List b, int at) => ByteData.sublistView(b).getUint64(at);
List<_Box> _boxes(Uint8List b) {
  final result = <_Box>[];
  var offset = 0;
  while (offset + 8 <= b.length && result.length < 10000) {
    var size = _u32(b, offset), head = 8;
    final type = latin1.decode(b.sublist(offset + 4, offset + 8));
    if (size == 1) {
      if (offset + 16 > b.length) break;
      size = _u64(b, offset + 8);
      head = 16;
    }
    if (size == 0) size = b.length - offset;
    if (size < head || offset + size > b.length) break;
    result.add(
      _Box(type, Uint8List.sublistView(b, offset + head, offset + size)),
    );
    offset += size;
  }
  return result;
}

Uint8List? _child(Uint8List b, String type) {
  for (final box in _boxes(b)) {
    if (box.type == type) return box.data;
  }
  return null;
}

Future<List<BookChapter>> readM4bChapters(String source) async {
  RandomAccessFile? file;
  try {
    final content = source.startsWith('content:');
    if (!content) file = await File(source).open();
    Future<Uint8List> read(int offset, int count) async {
      if (offset < 0 || count < 0 || count > 16 * 1024 * 1024) {
        throw const FormatException('Metadata limit');
      }
      if (!content) {
        await file!.setPosition(offset);
        return file!.read(count);
      }
      final result = BytesBuilder(copy: false);
      while (count > 0) {
        final size = count > 1024 * 1024 ? 1024 * 1024 : count;
        final bytes =
            await audioFolderChannel.invokeMethod<Uint8List>('readRange', {
              'uri': source,
              'offset': offset,
              'count': size,
            }) ??
            Uint8List(0);
        result.add(bytes);
        offset += bytes.length;
        count -= bytes.length;
        if (bytes.length < size) break;
      }
      return result.takeBytes();
    }

    var offset = 0;
    for (var n = 0; n < 10000; n++) {
      final h = await read(offset, 16);
      if (h.length < 8) break;
      var size = _u32(h, 0), head = 8;
      if (size == 1) {
        if (h.length < 16) break;
        size = _u64(h, 8);
        head = 16;
      }
      if (size < head || size > 1 << 50) break;
      if (latin1.decode(h.sublist(4, 8)) == 'moov') {
        if (size - head > 16 * 1024 * 1024) return [];
        final moov = await read(offset + head, size - head);
        if (moov.length != size - head) return [];
        return await parseChapterMovie(moov, read);
      }
      offset += size;
    }
    return [];
  } finally {
    await file?.close();
  }
}

Future<List<BookChapter>> parseChapterMovie(
  Uint8List moov,
  Future<Uint8List> Function(int, int) read,
) async {
  final udta = _child(moov, 'udta');
  final chpl = udta == null ? null : _child(udta, 'chpl');
  if (chpl != null && chpl.length >= 5) {
    var offset = chpl[0] == 1 ? 8 : 4;
    final count = chpl[offset++];
    final chapters = <BookChapter>[];
    for (var i = 0; i < count; i++) {
      if (offset + 9 > chpl.length) {
        throw const FormatException('Truncated chapters');
      }
      final time = _u64(chpl, offset) ~/ 10000;
      offset += 8;
      final length = chpl[offset++];
      if (offset + length > chpl.length) {
        throw const FormatException('Truncated title');
      }
      chapters.add(
        BookChapter(
          utf8.decode(
            chpl.sublist(offset, offset + length),
            allowMalformed: true,
          ),
          time,
        ),
      );
      offset += length;
    }
    return _ordered(chapters);
  }
  // QuickTime chapter track referenced by tref/chap, not an arbitrary subtitle track.
  final tracks = _boxes(moov)
      .where((b) => b.type == 'trak')
      .map((b) => b.data)
      .toList();
  final references = <int>{};
  for (final track in tracks) {
    final tref = _child(track, 'tref');
    final chap = tref == null ? null : _child(tref, 'chap');
    if (chap != null) {
      for (var i = 0; i + 4 <= chap.length; i += 4) {
        references.add(_u32(chap, i));
      }
    }
  }
  for (final track in tracks) {
    final tkhd = _child(track, 'tkhd');
    if (tkhd == null ||
        tkhd.length < 24 ||
        !references.contains(_u32(tkhd, tkhd[0] == 1 ? 20 : 12))) {
      continue;
    }
    final mdia = _child(track, 'mdia');
    if (mdia == null) continue;
    final mdhd = _child(mdia, 'mdhd'), minf = _child(mdia, 'minf');
    if (mdhd == null || minf == null) continue;
    final scale = _u32(mdhd, mdhd[0] == 1 ? 20 : 12);
    if (scale == 0) continue;
    final stbl = _child(minf, 'stbl');
    if (stbl == null) continue;
    final sizes = _child(stbl, 'stsz'),
        timing = _child(stbl, 'stts'),
        mapping = _child(stbl, 'stsc');
    final co64 = _child(stbl, 'co64'), co32 = _child(stbl, 'stco');
    final chunks = co64 ?? co32;
    if (sizes == null || timing == null || mapping == null || chunks == null) {
      continue;
    }
    if (_u32(mapping, 4) > 10000 || _u32(timing, 4) > 10000) {
      throw const FormatException('Chapter table limit');
    }
    final sampleCount = _u32(sizes, 8), fixed = _u32(sizes, 4);
    if (sampleCount > 10000) throw const FormatException('Too many chapters');
    final lengths = [
      for (var i = 0; i < sampleCount; i++)
        fixed == 0 ? _u32(sizes, 12 + i * 4) : fixed,
    ];
    final starts = <int>[];
    var time = 0;
    for (var i = 0; i < _u32(timing, 4); i++) {
      final count = _u32(timing, 8 + i * 8), delta = _u32(timing, 12 + i * 8);
      if (starts.length + count > 10000) {
        throw const FormatException('Too many chapter samples');
      }
      for (var j = 0; j < count; j++) {
        starts.add(time * 1000 ~/ scale);
        time += delta;
      }
    }
    if (starts.length != sampleCount) continue;
    final entries = [
      for (var i = 0; i < _u32(mapping, 4); i++)
        (_u32(mapping, 8 + i * 12), _u32(mapping, 12 + i * 12)),
    ];
    if (entries.isEmpty || entries.first.$1 != 1) continue;
    final chapterList = <BookChapter>[];
    var sample = 0, mapIndex = 0;
    final chunkCount = _u32(chunks, 4);
    if (chunkCount > 10000) {
      throw const FormatException('Too many chapter chunks');
    }
    for (var c = 1; c <= chunkCount && sample < sampleCount; c++) {
      while (mapIndex + 1 < entries.length && entries[mapIndex + 1].$1 <= c) {
        mapIndex++;
      }
      var offset = co64 != null
          ? _u64(chunks, 8 + (c - 1) * 8)
          : _u32(chunks, 8 + (c - 1) * 4);
      for (var j = 0; j < entries[mapIndex].$2 && sample < sampleCount; j++) {
        final length = lengths[sample];
        if (length < 2 || length > 65536) {
          throw const FormatException('Chapter title limit');
        }
        final data = await read(offset, length);
        if (data.length != length) {
          throw const FormatException('Truncated chapter text');
        }
        final textLength = (data[0] << 8) | data[1];
        if (textLength > data.length - 2) {
          throw const FormatException('Invalid chapter text');
        }
        chapterList.add(
          BookChapter(
            utf8.decode(data.sublist(2, 2 + textLength), allowMalformed: true),
            starts[sample],
          ),
        );
        offset += length;
        sample++;
      }
    }
    if (chapterList.length == sampleCount) return _ordered(chapterList);
  }
  return [];
}

List<BookChapter> _ordered(List<BookChapter> list) {
  for (var i = 0; i < list.length; i++) {
    if (list[i].startMs < 0 ||
        (i > 0 && list[i].startMs <= list[i - 1].startMs)) {
      throw const FormatException('Chapter order');
    }
    if (list[i].title.trim().isEmpty) {
      list[i] = BookChapter('Глава ${i + 1}', list[i].startMs);
    }
  }
  return list;
}
