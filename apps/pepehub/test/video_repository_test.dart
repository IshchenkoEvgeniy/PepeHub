import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_import.dart';
import 'package:pepehub/video/video_repository.dart';

void main() {
  test(
    'reconnecting a course retains IDs, position, favorite and book outbox',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db), videos = VideoRepository(Repository(db));
      await repo.addBook('Existing book', '', 'epub');
      final outbox = await db
          .customSelect('SELECT COUNT(*) AS count FROM outbox')
          .getSingle();
      final course = await videos.addSources(
        title: 'English',
        root: 'course-folder',
        sources: [const VideoSourceDraft('Lesson 1.mp4', 'Lesson 1')],
      );
      final first = (await videos.lessons(itemId: course.id)).single;
      await videos.checkpoint(
        lesson: first,
        progress: VideoProgress(
          lessonId: first.id,
          mediaVersion: first.mediaVersion,
          positionMs: 42000,
          speed: 1.5,
          updatedAt: DateTime.utc(2026, 10, 14),
        ),
        intervals: [],
        durationMs: 60000,
      );
      await videos.setFavorite(course, true);
      final reconnected = await videos.addSources(
        title: 'Automatic title',
        root: 'course-folder',
        sources: [
          const VideoSourceDraft('Lesson 1.mp4', 'Automatic lesson title'),
          const VideoSourceDraft('Lesson 2.mp4', 'Lesson 2'),
        ],
      );
      expect(reconnected.id, course.id);
      expect(reconnected.title, 'English');
      expect(reconnected.favorite, isTrue);
      final lessons = await videos.lessons(itemId: course.id);
      expect(lessons, hasLength(2));
      expect(lessons.first.id, first.id);
      expect(lessons.first.title, 'Lesson 1');
      expect((await videos.progress(first))!.positionMs, 42000);
      final after = await db
          .customSelect('SELECT COUNT(*) AS count FROM outbox')
          .getSingle();
      expect(after.read<int>('count'), outbox.read<int>('count'));
      expect(await repo.records('book'), hasLength(1));
    },
  );

  test(
    'checkpoint grows a record rather than creating duplicate minutes',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db), videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'Lecture',
        sources: [const VideoSourceDraft('a.mp4', 'Lecture')],
      );
      final lesson = (await videos.lessons(itemId: item.id)).single;
      for (final ms in [1000, 2000, 3000]) {
        await videos.checkpoint(
          lesson: lesson,
          progress: VideoProgress(
            lessonId: lesson.id,
            mediaVersion: lesson.mediaVersion,
            positionMs: ms,
            speed: 1,
            updatedAt: DateTime.utc(2026, 10, 14),
          ),
          intervals: [
            VideoInterval(
              id: 'stable',
              sessionId: 's',
              lessonId: lesson.id,
              mediaVersion: lesson.mediaVersion,
              mode: VideoActivityMode.visual,
              startedAt: DateTime.utc(2026, 10, 14),
              offsetMinutes: 0,
              startMs: 0,
              endMs: ms,
              wallMs: ms,
              speed: 1,
            ),
          ],
        );
      }
      expect(await videos.intervals(), hasLength(1));
      expect((await videos.intervals()).single.wallMs, 3000);
      expect((await repo.record('stable'))!.revision, 3);
      // Deletions must not be revived by an old checkpoint.
      await db.customStatement('UPDATE records SET deleted=1 WHERE id=?', [
        'stable',
      ]);
      await db.customStatement('UPDATE records SET payload=? WHERE id=?', [
        jsonEncode({...lesson.toJson(), 'mediaVersion': 'replacement'}),
        lesson.id,
      ]);
      expect(
        await videos.progress(
          VideoLesson.fromJson(lesson.id, {
            ...lesson.toJson(),
            'mediaVersion': 'replacement',
          }),
        ),
        isNull,
      );
    },
  );

  test(
    'folder scan ignores support files and sorts lessons naturally',
    () async {
      final temp = await Directory.systemTemp.createTemp('pepehub-video-');
      addTearDown(() => temp.delete(recursive: true));
      for (final name in [
        'Module 2/Lesson 10.mp4',
        'Module 2/Lesson 2.mkv',
        'Module 1/Lesson 1.webm',
        '.pepehub/preview.mp4',
        'readme.txt',
      ]) {
        final file = File(p.join(temp.path, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes([0]);
      }
      final selection = await scanVideoFolder(temp.path);
      expect(selection.sources.map((s) => s.title), [
        'Lesson 1',
        'Lesson 2',
        'Lesson 10',
      ]);
      expect(selection.sources.first.module, 'Module 1');
      expect(selection.root, temp.path);
      expect(
        validateVideoUrl(' https://example.com/lesson.mp4?token=123 '),
        'https://example.com/lesson.mp4?token=123',
      );
      for (final input in [
        'javascript:alert(1)',
        'file:///local.mp4',
        'https://',
        'https://user:password@example.com/a',
      ]) {
        expect(() => validateVideoUrl(input), throwsArgumentError);
      }
    },
  );
}
