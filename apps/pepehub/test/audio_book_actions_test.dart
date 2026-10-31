import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_book_actions.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_book_actions.dart';
import 'package:pepehub/ui/library_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late Directory temp;
  late File first, second, unrelated;
  late String id;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    temp = await Directory.systemTemp.createTemp('pepehub-audio-actions-');
    assets = AssetStore(repo, Directory('${temp.path}/managed'));
    first = await File('${temp.path}/01.mp3')
        .writeAsString('ID3 example track one');
    second = await File('${temp.path}/02.mp3')
        .writeAsString('ID3 example track two');
    unrelated = await File('${temp.path}/notes.txt').writeAsString('keep me');
    final book = await assets.connectAudioFolder(
      [
        FolderAudioFile(first.path, '01.mp3'),
        FolderAudioFile(second.path, '02.mp3'),
      ],
      root: temp.path,
      title: 'Аудиокнига',
    );
    id = book.bookId;
    await repo.setMeta('audio-book:$id', '{"favorite":true}');
    await repo.setMeta('audio-cover:$id', unrelated.path);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioFolderChannel, null);
    await db.close();
    await temp.delete(recursive: true);
  });
  test(
    'hide survives folder refresh and can be undone without losing tracks',
    () async {
      final scan = AudioFolder('Test', [
        FolderAudioFile(first.path, '01.mp3'),
        FolderAudioFile(second.path, '02.mp3'),
      ], root: temp.path);
      await connectAudioCatalog(
        assets,
        scan,
        groupAudioCatalog(scan, mode: 'single'),
        mode: 'single',
      );
      await AudioBookActions(assets).hide(id);
      await AudioRoots(assets)
          .refresh((await AudioRoots(assets).list()).single, replacement: scan);
      expect(await repo.meta('audio-library-hidden:$id'), '1');
      expect(await first.exists(), true);
      expect(await assets.audioTracks(id), hasLength(2));
      await AudioBookActions(assets).hide(id, hidden: false);
      expect(await repo.meta('audio-library-hidden:$id'), '0');
      expect(await repo.meta('audio-book:$id'), '{"favorite":true}');
    },
  );
  test('delete removes only selected audio files and retains identity, artwork and progress', () async {
    await AudioBookActions(assets).deleteForever(id);
    expect(await first.exists(), false);
    expect(await second.exists(), false);
    expect(await unrelated.readAsString(), 'keep me');
    expect((await repo.record(id))!.deleted, false);
    expect(await assets.audioTracks(id), hasLength(2));
    expect(await repo.meta('audio-cover:$id'), unrelated.path);
    expect(await repo.meta('audio-book:$id'), '{"favorite":true}');
    expect(await repo.meta('audio-user-hidden:$id'), '1');
    await AudioBookActions(assets).deleteForever(id);
  });
  test('changed later track fails before any file is deleted', () async {
    await second.writeAsString('changed size');
    await expectLater(
      AudioBookActions(assets).deleteForever(id),
      throwsStateError,
    );
    expect(await first.exists(), true);
    expect(await repo.meta('audio-user-hidden:$id'), isNull);
  });
  test('shared physical tracks cannot be deleted from another book', () async {
    await assets.connectAudioFolder(
      [XFile(first.path)],
      root: '${temp.path}/other-binding',
      title: 'Другая книга',
    );
    await expectLater(
      AudioBookActions(assets).deleteForever(id),
      throwsStateError,
    );
    expect(await first.exists(), true);
    expect(await second.exists(), true);
  });
  test(
    'Android preflights every document and forwards write access failure',
    () async {
      final tracks = await assets.audioTracks(id);
      for (var i = 0; i < tracks.length; i++) {
        await db.customStatement(
          'UPDATE audio_resources SET path=? WHERE sha256=?',
          ['content://audio.test/tree/books/document/$i', tracks[i].hash],
        );
      }
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioFolderChannel, (call) async {
            calls.add(call);
            if ((call.arguments as Map)['uri'].endsWith('/1')) {
              throw PlatformException(
                code: 'book_write_permission',
                details: {'root': 'content://audio.test/tree/books'},
              );
            }
            return null;
          });
      await expectLater(
        AudioBookActions(assets).deleteForever(id),
        throwsA(isA<ReadingBookWriteAccessRequired>()),
      );
      expect(calls, hasLength(2));
      expect(
        calls.every((c) => (c.arguments as Map)['checkOnly'] == true),
        true,
      );
      expect(calls.first.arguments['hash'], 'external:${tracks.first.bytes}');
      expect(await repo.meta('audio-user-hidden:$id'), isNull);
    },
  );
  testWidgets('audiobook menu exposes hiding and file deletion', (
    tester,
  ) async {
    await repo.setMeta('library-section', 'audio');
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryPage(repository: repo, assets: assets),
      ),
    );
    final state = tester.state(find.byType(LibraryPage)) as dynamic;
    final library = state.obsidianLibrary;
    await ready(tester, () => !state.loading && !library.loading);
    await tester.tap(find.byTooltip('Действия с книгой').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Удалить файлы аудиокниги…'));
    expect(find.text('Убрать из списка'), findsOneWidget);
    expect(find.text('Удалить файлы аудиокниги…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await library.idle;
    });
  });
}
