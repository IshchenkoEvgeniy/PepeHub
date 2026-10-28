import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_daily_totals.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/database_files.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _legacyVideoIndexes = {
  'video_lesson_item': r"(json_extract(payload,'$.itemId'),json_extract(payload,'$.ordinal'),id) WHERE type='video_lesson' AND deleted=0",
  'video_interval_lesson': r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion')) WHERE type='video_interval' AND deleted=0",
  'video_interval_history': r"(COALESCE(json_extract(payload,'$.startEpochMs'),CAST(ROUND(unixepoch(json_extract(payload,'$.startedAt'),'subsec')*1000) AS INTEGER)) DESC,id DESC) WHERE type='video_interval' AND deleted=0",
  'video_annotation_lesson': r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.startMs'),id) WHERE type='video_annotation' AND deleted=0",
  'video_subtitle_lesson': r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.digest')) WHERE type='video_subtitle' AND deleted=0",
};

const _videoTypes = [
  'video_lesson',
  'video_interval',
  'video_annotation',
  'video_subtitle',
];

const _featureTables = [
  'reading_span_index_v1',
  'reading_span_dirty_v1',
  'audio_daily_totals_v1',
  'peer_sync_files',
  'peer_sync_deletions',
  'peer_sync_scan_cache',
  'peer_sync_remote_index',
  'peer_app_versions',
  'peer_app_projection',
  'peer_app_alias',
  'cloud_local_state',
  'legacy_cloud_outbox',
];

Map<String, dynamic> _listen(String book, {int wall = 1000}) => {
  'kind': 'listen',
  'bookId': book,
  'trackId': 'track',
  'wallMs': wall,
  'positionMs': 0,
  'endMs': wall,
  'speed': 1.0,
  'localDay': '2026-10-23',
  'at': '2026-10-23T12:00:00Z',
  'offsetMinutes': 0,
};

Set<String> _names(sqlite.Database raw, String type) => {
  for (final row in raw.select('SELECT name FROM sqlite_master WHERE type=?', [
    type,
  ]))
    row['name'] as String,
};

void main() {
  late Directory root;
  late File file;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pepe-schema-');
    file = File('${root.path}/pepehub.sqlite');
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// A current database with one listening event and one reading session.
  Future<void> populated() async {
    final db = AppDatabase(NativeDatabase(file));
    final repo = Repository(db);
    await AudioJournal(repo).put('audio_event', 'event', _listen('book'));
    await repo.setMeta('reading-session:s1', jsonEncode({'spans': []}));
    await db.close();
  }

  Future<AppDatabase> reopen() async {
    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    return db;
  }

  test(
    'a new database contains the whole schema at the current version',
    () async {
      final db = AppDatabase(NativeDatabase(file));
      await db.customSelect('SELECT 1').get();
      // A damaged payload of any type must not break indexed writes.
      await db.customStatement(
        "INSERT INTO records VALUES('damaged','book',1,0,'{broken')",
      );
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      try {
        expect(
          raw.select('PRAGMA user_version').single.values.first,
          currentDatabaseVersion,
        );
        expect(_names(raw, 'table'), containsAll(_featureTables));
        expect(
          _names(raw, 'index'),
          containsAll(['records_audio_day_v2', 'video_interval_history']),
        );
        expect(_names(raw, 'index'), isNot(contains('records_audio_day')));
      } finally {
        raw.close();
      }
    },
  );

  test(
    'version 3 with existing read models upgrades without double counting',
    () async {
      await populated();
      final raw = sqlite.sqlite3.open(file.path);
      // Shape of a version 3 user who opened statistics but never synced.
      raw.execute('DROP INDEX records_audio_day_v2');
      raw.execute(
        "CREATE INDEX records_audio_day ON records(type,json_extract(payload,'\$.localDay'),json_extract(payload,'\$.bookId'))",
      );
      raw.execute('DROP TABLE peer_app_alias');
      raw.execute('DROP INDEX peer_app_projection_target');
      // Existing indexes must be replaced, not retained by IF NOT EXISTS.
      for (final entry in _legacyVideoIndexes.entries) {
        raw.execute('DROP INDEX ${entry.key}');
        raw.execute('CREATE INDEX ${entry.key} ON records ${entry.value}');
      }
      raw.execute('PRAGMA user_version=3');
      raw.close();

      final db = await reopen();
      try {
        final totals = await AudioDailyStore(Repository(db)).lifetime();
        expect(totals.days, {'2026-10-23': 1000});
        expect(
          await db.customSelect('SELECT * FROM peer_app_alias').get(),
          isEmpty,
        );
      } finally {
        await db.close();
      }
      final check = sqlite.sqlite3.open(file.path);
      try {
        expect(check.select('PRAGMA user_version').single.values.first, 4);
        expect(_names(check, 'index'), contains('records_audio_day_v2'));
        expect(_names(check, 'index'), isNot(contains('records_audio_day')));
        for (final name in _legacyVideoIndexes.keys) {
          expect(
            check.select('SELECT sql FROM sqlite_master WHERE name=?', [
              name,
            ]).single['sql'],
            contains('json_valid(payload)'),
            reason: name,
          );
        }
        for (final type in _videoTypes) {
          check.execute('INSERT INTO records VALUES(?,?,1,0,?)', [
            'damaged-$type',
            type,
            '{broken',
          ]);
        }
        expect(_names(check, 'index'), contains('peer_app_projection_target'));
      } finally {
        check.close();
      }
    },
  );

  test(
    'version 3 without read models backfills them despite a damaged record',
    () async {
      await populated();
      final raw = sqlite.sqlite3.open(file.path);
      for (final trigger in _names(raw, 'trigger')) {
        raw.execute('DROP TRIGGER "$trigger"');
      }
      raw.execute('DROP INDEX records_audio_day_v2');
      for (final name in _legacyVideoIndexes.keys) {
        raw.execute('DROP INDEX $name');
      }
      for (final table in _featureTables) {
        raw.execute('DROP TABLE "$table"');
      }
      raw.execute("INSERT INTO records VALUES('damaged','book',1,0,'{broken')");
      for (final type in _videoTypes) {
        raw.execute('INSERT INTO records VALUES(?,?,1,0,?)', [
          'damaged-$type',
          type,
          '{broken',
        ]);
      }
      raw.execute('PRAGMA user_version=3');
      raw.close();

      final db = await reopen();
      try {
        final totals = await AudioDailyStore(Repository(db)).lifetime();
        expect(totals.books, {'book': 1000});
        expect(
          (await db
                  .customSelect('SELECT session_key FROM reading_span_dirty_v1')
                  .get())
              .map((r) => r.read<String>('session_key')),
          ['reading-session:s1'],
        );
        // Triggers are live again after the upgrade.
        await AudioJournal(Repository(db))
            .put('audio_event', 'second', _listen('book', wall: 500));
        expect((await AudioDailyStore(Repository(db)).lifetime()).books, {
          'book': 1500,
        });
      } finally {
        await db.close();
      }
    },
  );

  test('video readers skip damaged payloads after indexed writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Valid course',
      sources: [const VideoSourceDraft('lesson.mp4', 'Valid lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    for (final type in _videoTypes) {
      await db.customStatement('INSERT INTO records VALUES(?,?,1,0,?)', [
        'damaged-$type',
        type,
        '{broken',
      ]);
    }
    expect((await videos.lessons()).single.id, lesson.id);
    expect((await videos.lessons(itemId: item.id)).single.id, lesson.id);
    expect(await videos.annotations(lesson), isEmpty);
    expect(await videos.subtitles(lesson), isEmpty);
    expect(await videos.intervals(), isEmpty);
    expect(
      await videos.intervals(lessonIds: {lesson.id}, music: false),
      isEmpty,
    );
    expect((await videos.history()).intervals, isEmpty);
    expect(
      (await videos.history(lessonIds: {lesson.id}, music: false)).intervals,
      isEmpty,
    );
  });

  test('foreign reader sources use the materialized target index', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final plan = await db
        .customSelect(
          "EXPLAIN QUERY PLAN SELECT target AS id FROM peer_app_projection "
          "WHERE materialized=1 AND target IN "
          "(SELECT 'm:reading-session:'||value FROM json_each('[\"s1\"]'))",
        )
        .get();
    expect(
      plan.map((row) => row.read<String>('detail')).join('\n'),
      matches(
        r'SEARCH peer_app_projection USING (?:COVERING )?INDEX peer_app_projection_target',
      ),
    );
  });
}
