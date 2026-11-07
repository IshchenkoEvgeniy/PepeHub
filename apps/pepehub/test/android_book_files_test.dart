import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/media/android_book_files.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(bookFilesChannel, null));

  Map<String, Object> book(String name, {bool persistent = true}) => {
    'path': 'content://books/document/$name',
    'name': name,
    'bytes': 100,
    'persistent': persistent,
  };

  test('incoming document queue stays serial through failed adds', () async {
    final first = Completer<void>();
    final started = Completer<void>();
    var next = 0;
    final opened = <String>[], errors = <Object>[];
    messenger.setMockMethodCallHandler(bookFilesChannel, (call) async {
      if (call.method == 'next') {
        next++;
        if (next <= 2) return book('book$next.pdf');
        return null;
      }
      throw StateError('Unexpected native call ${call.method}');
    });
    final receiver = AndroidBookFiles(
      onError: errors.add,
      onFile: (source) async {
        expect(source.persistent, true);
        opened.add(source.file.name);
        if (opened.length == 1) {
          started.complete();
          await first.future;
          throw const FormatException('broken file');
        }
      },
    );
    final draining = receiver.drain();
    await started.future;
    await receiver
        .drain(); // warm intent while validation of the first file runs
    expect(next, 1);
    first.complete();
    await draining;
    expect(opened, ['book1.pdf', 'book2.pdf']);
    expect(errors, hasLength(1));
    receiver.dispose();
    await receiver.drain();
    expect(opened, hasLength(2));
  });

  test('native bad URI does not strand the next valid file', () async {
    var next = 0;
    final opened = <String>[], errors = <Object>[];
    messenger.setMockMethodCallHandler(bookFilesChannel, (call) async {
      if (call.method == 'next') {
        if (++next == 1) {
          throw PlatformException(
            code: 'book_file',
            message: 'permission lost',
          );
        }
        if (next == 2) return book('valid.epub', persistent: false);
      }
      return null;
    });
    final receiver = AndroidBookFiles(
      onError: errors.add,
      onFile: (source) async {
        expect(source.persistent, false);
        opened.add(source.file.name);
      },
    );
    await receiver.drain();
    expect(errors, hasLength(1));
    expect(opened, ['valid.epub']);
    receiver.dispose();
  });

  test('picker returns the original document URI', () async {
    messenger.setMockMethodCallHandler(bookFilesChannel, (call) async {
      expect(call.method, 'pick');
      expect(call.arguments['mimeTypes'], ['application/epub+zip']);
      return book('original.epub');
    });
    final source = (await pickAndroidBook(['application/epub+zip']))!;
    expect(source.persistent, true);
    expect(source.file.path, 'content://books/document/original.epub');
    expect(await source.file.length(), 100);
  });

  test(
    'share passes all audiobook URIs without copying and a precise PDF type',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(bookFilesChannel, (call) async {
        calls.add(call);
        return null;
      });
      LocalAsset asset(String name, String path) => LocalAsset(
        id: name,
        bookId: 'b',
        filename: name,
        path: path,
        hash: name,
        bytes: 100,
      );
      await shareBookFiles([
        asset('One.mp3', 'content://books/1'),
        asset('Two.m4b', 'content://books/2'),
      ]);
      expect(calls.single.arguments['paths'], [
        'content://books/1',
        'content://books/2',
      ]);
      expect(calls.single.arguments['mime'], 'audio/*');
      await shareBookFiles([asset('Title.PDF', '/files/audio/abc.pdf')]);
      expect(calls.last.arguments['mime'], 'application/pdf');
      expect(calls.last.arguments['names'], ['Title.PDF']);
      await expectLater(shareBookFiles([]), throwsStateError);
      expect(calls, hasLength(2));
    },
  );
}
