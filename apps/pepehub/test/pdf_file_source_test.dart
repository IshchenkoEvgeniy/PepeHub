import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/pdf_file_source.dart';

import 'support/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final direct in [true, false]) {
    test(
      'SAF PDF ${direct ? 'opens a retained descriptor without copying' : 'falls back to a verified cached stream'}',
      () async {
        final root = await Directory.systemTemp.createTemp('pepe-pdf-source-');
        final db = AppDatabase(NativeDatabase.memory());
        final data = twoPagePdf();
        final asset = LocalAsset(
          id: 'pdf',
          bookId: 'pdf',
          filename: 'book.pdf',
          path: 'content://books/book.pdf',
          hash: sha256.convert(data).toString(),
          bytes: data.length,
        );
        final assets = AssetStore(Repository(db), root);
        final calls = <String>[];
        var read = false;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'openPdfDescriptor':
              expect(call.arguments['uri'], asset.path);
              expect(call.arguments['bytes'], asset.bytes);
              if (!direct) throw PlatformException(code: 'not-seekable');
              return {'path': '/proc/self/fd/42', 'handle': 'pdf-handle'};
            case 'closePdfDescriptor':
              expect(call.arguments['handle'], 'pdf-handle');
              return null;
            case 'open':
              return 'stream';
            case 'read':
              if (read) return Uint8List(0);
              read = true;
              return data;
            case 'close':
              return null;
            default:
              throw MissingPluginException(call.method);
          }
        });
        try {
          final source = await PdfFileSource.open(asset, assets);
          expect(source.isDirect, direct);
          if (direct) {
            expect(source.path, '/proc/self/fd/42');
            expect(calls, ['openPdfDescriptor']);
            expect(await root.list().isEmpty, isTrue);
          } else {
            expect(await File(source.path).readAsBytes(), data);
            expect(calls, [
              'openPdfDescriptor',
              'open',
              'read',
              'read',
              'close',
            ]);
          }
          await source.close();
          await source.close();
          expect(
            calls.where((call) => call == 'closePdfDescriptor').length,
            direct ? 1 : 0,
          );
        } finally {
          messenger.setMockMethodCallHandler(audioFolderChannel, null);
          await db.close();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
