import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_folder_sync.dart';
import 'package:pepehub/video/video_import.dart';
import 'package:pepehub/video/video_repository.dart';

class _Folders {
  final db = AppDatabase(NativeDatabase.memory());
  late final videos = VideoRepository(Repository(db));
  late Directory parent, root;
  late VideoItem item;
  Future<void> create() async {
    parent = await Directory('build/video-folder-tests').absolute
        .create(recursive: true);
    root = await parent.createTemp('case-');
    await File(p.join(root.path, '1.mp4'))
        .writeAsBytes(List.generate(200000, (i) => i % 251));
    await File(p.join(root.path, '2.mp4'))
        .writeAsBytes(List.generate(100000, (i) => (i + 23) % 251));
    final selection = await scanVideoFolder(root.path);
    item = await videos.addSources(
      title: 'Course',
      sources: selection.sources,
      root: root.path,
    );
  }

  Future<void> close() async {
    await db.close();
    final target = await root.resolveSymbolicLinks(),
        within = await parent.resolveSymbolicLinks();
    if (!p.isWithin(within, target)) {
      throw StateError('Unexpected temporary folder target');
    }
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('confirmed rename preserves lesson/version/progress/notes and manual course order', () async {
    final h = _Folders();
    await h.create();
    addTearDown(h.close);
    final lessons = await h.videos.lessons(itemId: h.item.id),
        first = (await h.videos.lessons(itemId: h.item.id)).first;
    await h.videos.checkpoint(
      lesson: first,
      progress: VideoProgress(
        lessonId: first.id,
        mediaVersion: first.mediaVersion,
        positionMs: 25000,
        speed: 1.25,
        updatedAt: DateTime.utc(2026, 10, 14),
      ),
      intervals: [],
    );
    final note = await h.videos.saveAnnotation(
      first,
      title: 'Quote',
      body: 'Keep it',
      startMs: 24000,
    );
    await h.videos.saveCourseStructure(
      h.item,
      title: 'Custom',
      token: VideoRepository.structureToken(h.item, lessons),
      ordered: [
        VideoLessonEdit(lessons.last.id, 'Second first', 'My module'),
        VideoLessonEdit(first.id, 'Named lesson', 'My module'),
      ],
    );
    final item = (await h.videos.items()).single;
    await File(first.source).rename(p.join(h.root.path, 'renamed.mp4'));
    final preview = await previewVideoFolder(
      h.videos,
      item,
      await scanVideoFolder(h.root.path),
    );
    expect(preview.renames.single.lesson.id, first.id);
    await preview.apply({first.id});
    final next = await h.videos.lessons(itemId: item.id);
    expect(next.last.id, first.id);
    expect(next.last.title, 'Named lesson');
    expect(next.last.module, 'My module');
    expect(next.last.mediaVersion, first.mediaVersion);
    expect(next.last.source, endsWith('renamed.mp4'));
    expect((await h.videos.progress(next.last))!.positionMs, 25000);
    expect((await h.videos.annotations(next.last)).single.id, note.id);
    expect((await h.videos.items()).single.title, 'Custom');
  });
  test('changed contents create a new version while missing lessons remain in the catalog', () async {
    final h = _Folders();
    await h.create();
    addTearDown(h.close);
    final before = await h.videos.lessons(itemId: h.item.id);
    await File(before.first.source).writeAsBytes(List.filled(210000, 72));
    await File(before.last.source).delete();
    await File(p.join(h.root.path, '3.mp4')).writeAsBytes(List.filled(5000, 4));
    final preview = await previewVideoFolder(
      h.videos,
      h.item,
      await scanVideoFolder(h.root.path),
    );
    expect(preview.changed, {before.first.id});
    expect(preview.missingCount, 1);
    await preview.apply({});
    final next = await h.videos.lessons(itemId: h.item.id);
    expect(next, hasLength(3));
    expect(next.first.id, before.first.id);
    expect(next.first.mediaVersion, isNot(before.first.mediaVersion));
    expect(next.first.durationMs, isNull);
    expect(next[1].id, before.last.id);
    expect(next[1].available, isFalse);
    expect(next.last.title, '3');
  });
  test('disconnect and reconnect preserve the logical course; stale preview is rejected', () async {
    final h = _Folders();
    await h.create();
    addTearDown(h.close);
    final before = await h.videos.lessons(itemId: h.item.id);
    await h.videos.setRootConnection(h.item, false);
    expect((await h.videos.items()).single.connected, isFalse);
    final other = await Directory(p.join(h.root.path, 'new-root')).create();
    for (final lesson in before) {
      await File(lesson.source)
          .copy(p.join(other.path, p.basename(lesson.source)));
    }
    final disconnected = (await h.videos.items()).single;
    final preview = await previewVideoFolder(
      h.videos,
      disconnected,
      await scanVideoFolder(other.path),
    );
    expect(preview.renames, hasLength(2));
    await preview.apply(before.map((lesson) => lesson.id).toSet());
    expect((await h.videos.items()).single.connected, isTrue);
    expect((await h.videos.items()).single.id, h.item.id);
    expect(
      (await h.videos.lessons(itemId: h.item.id))
          .map((lesson) => lesson.mediaVersion),
      before.map((lesson) => lesson.mediaVersion),
    );
    await expectLater(preview.apply({}), throwsStateError);
  });
  test(
    'ambiguous partial fingerprints never choose a rename automatically',
    () async {
      final h = _Folders();
      await h.create();
      addTearDown(h.close);
      final first = (await h.videos.lessons(itemId: h.item.id)).first;
      await File(first.source).copy(p.join(h.root.path, 'one-copy.mp4'));
      await File(first.source).copy(p.join(h.root.path, 'another-copy.mp4'));
      await File(first.source).delete();
      final preview = await previewVideoFolder(
        h.videos,
        h.item,
        await scanVideoFolder(h.root.path),
      );
      expect(preview.renames, isEmpty);
      await preview.apply({});
      expect(
        (await h.videos.lessons(itemId: h.item.id)).first.available,
        isFalse,
      );
    },
  );
  test('files changing after the preview cannot be confirmed against an obsolete sample', () async {
    final h = _Folders();
    await h.create();
    addTearDown(h.close);
    final preview = await previewVideoFolder(
      h.videos,
      h.item,
      await scanVideoFolder(h.root.path),
    );
    await File(p.join(h.root.path, '1.mp4'))
        .writeAsBytes(List.filled(211000, 9));
    await expectLater(preview.apply({}), throwsStateError);
    expect(
      (await h.videos.lessons(itemId: h.item.id)).first.mediaVersion,
      preview.lessons.first.mediaVersion,
    );
  });
}
