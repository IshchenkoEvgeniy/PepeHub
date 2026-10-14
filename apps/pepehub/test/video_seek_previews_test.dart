import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_seek_previews.dart';

class _Decoder implements VideoPreviewDecoder {
  final reads = <(String, int)>[];
  final pending = <Completer<Uint8List?>>[];
  bool closed = false;
  @override
  Future<Uint8List?> read(VideoLesson lesson, int positionMs) {
    reads.add((lesson.mediaVersion, positionMs));
    final result = Completer<Uint8List?>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

const lesson = VideoLesson(
  id: 'one',
  itemId: 'course',
  title: 'One',
  module: '',
  source: 'one.mp4',
  mediaVersion: 'v1',
  ordinal: 0,
);
Future<void> turn() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test(
    'late preview never replaces a newer request; cached frames avoid decoding',
    () async {
      final decoder = _Decoder(),
          previews = VideoSeekPreviews(
            factory: () => decoder,
            debounce: Duration.zero,
          );
      addTearDown(previews.dispose);
      previews.request(lesson, 1500, 10000);
      await turn();
      previews.request(lesson, 3500, 10000);
      await turn();
      decoder.pending.first.complete(Uint8List.fromList([1]));
      await turn();
      expect(previews.image, isNull);
      expect(decoder.reads, [('v1', 1000), ('v1', 3000)]);
      decoder.pending.last.complete(Uint8List.fromList([3]));
      await turn();
      expect(previews.image, [3]);
      previews.dismiss();
      previews.request(lesson, 3999, 10000);
      expect(previews.image, [3]);
      await turn();
      expect(decoder.reads, hasLength(2));
    },
  );
  test(
    'dismissal and disposal discard pending frames and close the decoder',
    () async {
      final decoder = _Decoder(),
          previews = VideoSeekPreviews(
            factory: () => decoder,
            debounce: Duration.zero,
          );
      previews.request(lesson, 9900, 10000);
      await turn();
      previews.dismiss();
      previews.dispose();
      decoder.pending.single.complete(Uint8List.fromList([9]));
      await turn();
      expect(previews.image, isNull);
      expect(decoder.closed, isTrue);
    },
  );
}
