import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/sync/peer/peer_diagnostics.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/sync/peer/peer_replica.dart';
import 'package:pepehub/sync/peer/peer_sync_log_page.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show ReplicaFixture, deviceA, deviceB;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  test('bounded journal persists, removes pairing secrets and clears saved history', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db), journal = PeerSyncJournal(Repository(db));
    addTearDown(db.close);
    addTearDown(journal.dispose);
    await journal.initialize();
    for (var i = 0; i < 420; i++) {
      journal.add('Шаг $i');
    }
    const secret = '012345678901234567890123456789012345678901234';
    journal.add(
      'Ошибка pepehub-peer://pair?key=$secret token=private-token content://private/file',
      level: PeerLogLevel.error,
    );
    await journal.flush();
    expect(journal.entries, hasLength(PeerSyncJournal.limit));
    expect(journal.export(), isNot(contains(secret)));
    expect(journal.export(), isNot(contains('private-token')));
    expect(journal.export(), isNot(contains('content://private')));
    final reopened = PeerSyncJournal(repo);
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.entries.last.level, PeerLogLevel.error);
    expect(reopened.entries.first.message, 'Шаг 21');
    await reopened.clear();
    final cleared = PeerSyncJournal(repo);
    addTearDown(cleared.dispose);
    await cleared.initialize();
    expect(cleared.entries, isEmpty);
  });

  test('operational errors describe the cause without dumping arbitrary private exception data', () {
    expect(
      peerFailureDescription(
        const SocketException('refused', osError: OSError('refused', 10061)),
      ),
      contains('отклонило'),
    );
    expect(
      peerFailureDescription(
        const FileSystemException('full', 'private/path', OSError('full', 112)),
      ),
      contains('свободного места'),
    );
    expect(
      peerFailureDescription(TimeoutException('private payload')),
      contains('время ожидания'),
    );
    expect(
      peerFailureDescription(Exception('private note content')),
      isNot(contains('private note content')),
    );
    expect(
      peerFailureDescription(
        PlatformException(code: 'access', message: 'content://private/tree'),
      ),
      isNot(contains('content://private')),
    );
  });

  test('file progress resumes at the saved offset and completes only after hash validation', () async {
    final a = ReplicaFixture(deviceA), b = ReplicaFixture(deviceB);
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    final bytes = List.generate(peerChunkSize * 2 + 17, (i) => i % 251);
    await a.write('lesson.bin', bytes);
    final entry = (await a.replica.scan()).values.single;
    final offsets = <int>[], phases = <String>[];
    b.replica = PeerReplica(
      store: b.store,
      folder: b.replica.folder,
      device: deviceB,
      files: b.replica.files,
      work: b.replica.work,
      onTransfer: (_, offset, total) {
        offsets.add(offset);
        expect(total, bytes.length);
      },
      onPhase: (_, phase) => phases.add(phase),
    );
    await expectLater(
      b.replica.apply(entry, (path, hash, offset, count) async {
        if (offset > 0) throw const SocketException('test disconnect');
        return a.replica.files.read(path, offset, count);
      }),
      throwsA(isA<SocketException>()),
    );
    expect(offsets.last, peerChunkSize);
    expect(phases, isNot(contains('Файл сохранён')));
    offsets.clear();
    await b.replica.apply(
      entry,
      (path, hash, offset, count) => a.replica.files.read(path, offset, count),
    );
    expect(offsets.first, peerChunkSize);
    expect(offsets.last, bytes.length);
    expect(phases, contains('Возобновление загрузки'));
    expect(phases.last, 'Файл сохранён');
    expect(await b.replica.files.hash(entry.path), entry.hash);
  });

  test('remote folder failure reaches the requesting device with context and releases busy state', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await a.service.addFolder(
      a.shared.path,
      'English',
      sharedWith: {b.service.deviceId},
    );
    await b.service.addFolder(
      b.shared.path,
      'English',
      id: a.service.folders.single.id,
      sharedWith: {a.service.deviceId},
    );
    await a.shared.delete();
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, contains('На втором устройстве'));
    expect(b.service.error, contains('папка недоступна'));
    expect(b.service.busy, false);
    expect(b.service.journal.activities, isEmpty);
    expect(b.service.journal.export(), contains('English'));
    expect(
      a.service.journal.entries.any((e) => e.level == PeerLogLevel.error),
      true,
    );
  });

  test('application exchange logs counts and permission problems without logging card contents or keys', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    final invite = a.service.invitation('127.0.0.1');
    await b.service.pair(invite);
    await b.service.shareApplication(b.service.devices.single, true);
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.journal.entries.last.level, PeerLogLevel.warning);
    expect(b.service.status, contains('На втором устройстве включите'));
    await a.service.shareApplication(a.service.devices.single, true);
    await VocabularyRepository(a.repo)
        .save(front: 'private-word-content', back: 'private-translation');
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull);
    final text = b.service.journal.export();
    expect(text, contains('применено'));
    expect(text, contains('Обмен завершён'));
    expect(text, isNot(contains('private-word-content')));
    expect(text, isNot(contains('private-translation')));
    expect(text, isNot(contains(invite)));
    for (final peer in b.service.devices) {
      expect(
        text,
        isNot(contains((await b.service.secrets.read(peer.channel))!)),
      );
    }
  });

  test('authenticated remote task reports its live stage and exact failure to the initiator', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await b.service.shareApplication(b.service.devices.single, true);
    final port = a.service.port;
    final key = (await b.service.secrets.read(
      b.service.devices.single.channel,
    ))!;
    await a.service.setEnabled(false);
    var polls = 0;
    final remote = PeerWireServer(
      keyFor: (_) async => key,
      handle: (_, request, _) async => switch (request['op']) {
        'folders' => {'applicationData': true, 'folders': []},
        'app_manifest' => {'versions': []},
        'app_pull' => {'job': 'test-job'},
        'status' => {
          'job': ++polls == 1
              ? {
                  'state': 'running',
                  'progress': {
                    'stage': 'Проверка контрольной суммы',
                    'subject': 'English / lesson.mp4',
                    'bytes': 5,
                    'totalBytes': 10,
                  },
                }
              : {'state': 'failed', 'error': 'Недостаточно свободного места.'},
        },
        _ => throw StateError('Unexpected test operation'),
      },
    );
    await remote.start(address: InternetAddress.loopbackIPv4, port: port);
    addTearDown(remote.close);
    final seen = <String>[];
    b.service.journal.addListener(() {
      for (final activity in b.service.journal.activities) {
        if (activity.stage.startsWith('На втором устройстве:')) {
          seen.add(
            '${activity.stage} ${activity.subject} ${activity.bytes}/${activity.totalBytes}',
          );
        }
      }
    });
    await b.service.syncDevice(b.service.devices.single);
    expect(seen.any((s) => s.contains('English / lesson.mp4 5/10')), true);
    expect(
      b.service.error,
      contains('На втором устройстве: Недостаточно свободного места.'),
    );
    expect(b.service.journal.export(), contains('Проверка контрольной суммы'));
    expect(b.service.busy, false);
    expect(b.service.journal.activities, isEmpty);
  });

  testWidgets(
    'phone can inspect and copy logs during transfer with large text and filter errors',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final journal = PeerSyncJournal(Repository(db));
      await tester.runAsync(() async {
        await journal.initialize();
        journal.add('Соединение установлено.', peer: 'Мой компьютер');
        journal.add(
          'Устройство не ответило. Проверьте IP-адрес и брандмауэр.',
          peer: 'Мой компьютер',
          level: PeerLogLevel.error,
        );
        await journal.flush();
      });
      final activity = journal.start(
        'Получение файла',
        peer: 'Мой компьютер',
        subject: 'Английский / Урок 54.mp4',
      );
      journal.update(
        activity,
        bytes: 12 * 1024 * 1024,
        totalBytes: 32 * 1024 * 1024,
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final boundary = GlobalKey();
      await tester.runAsync(journal.flush);
      await tester.runAsync(() async {
        for (final family in ['Onest', 'Oswald']) {
          await (FontLoader(
            family,
          )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
        }
        final icons = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icons.exists()) {
          await (FontLoader('MaterialIcons')..addFont(
                icons.readAsBytes().then((bytes) => bytes.buffer.asByteData()),
              ))
              .load();
        }
      });
      Future<void> capture(String name) async {
        if (Platform.environment['PEPEHUB_CAPTURE_SYNC_UI'] != '1') return;
        await tester.runAsync(() async {
          final root =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await root.toImage(pixelRatio: 2);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('build/$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => RepaintBoundary(
            key: boundary,
            child: MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
          ),
          home: Scaffold(
            appBar: AppBar(title: const Text('Устройства и общие папки')),
            body: SingleChildScrollView(
              child: PeerSyncStatusPanel(journal: journal),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('12.0 МиБ / 32.0 МиБ · 38%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('peer-sync-progress-phone');
      await tester.tap(find.text('Журнал синхронизации'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Копировать журнал'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Копировать журнал'));
      await tester.pump();
      expect(copied, contains('Устройство не ответило'));
      await tester.tap(find.text('Только проблемы'));
      await tester.pump();
      expect(find.text('Соединение установлено.'), findsNothing);
      expect(
        find.text('Устройство не ответило. Проверьте IP-адрес и брандмауэр.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await capture('peer-sync-log-phone');
      journal.finish(activity);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(journal.flush);
      journal.dispose();
      await tester.runAsync(db.close);
    },
  );
}
