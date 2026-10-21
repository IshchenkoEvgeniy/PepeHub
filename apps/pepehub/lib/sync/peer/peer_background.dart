import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/database.dart';
import '../../data/repository.dart';
import 'peer_service.dart';
import 'peer_store.dart';
import 'peer_diagnostics.dart';

const peerBackgroundChannel = MethodChannel('app.pepehub/peer_background');

Future<void> claimPeerForeground() async {
  if (Platform.isAndroid) {
    await peerBackgroundChannel.invokeMethod<void>('claimForeground');
  }
}

void attachPeerBackground(PeerSyncService peers) {
  if (!Platform.isAndroid) return;
  peerBackgroundChannel.setMethodCallHandler((call) async {
    if (call.method == 'cancel') {
      peers.cancelExchange();
      peers.journal.add(
        'Фоновая передача остановлена пользователем или Android. Докачка сохранена.',
      );
    } else if (call.method == 'run' &&
        peers.enabled &&
        peers.backgroundSync &&
        !peers.busy) {
      peers.journal.add(
        'Android запустил короткий фоновый обмен данными приложения.',
      );
      await peers.syncAll(metadataOnly: true);
      await peers.journal.flush();
      return {'status': peers.error ?? 'Фоновый обмен данными завершён'};
    } else if (call.method == 'run') {
      return {
        'status':
            'Фоновый обмен пропущен: выключен или уже выполняется передача',
      };
    }
    return null;
  });
}

Future<void> runPeerBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase? db;
  PeerSyncService? peers;
  var cancelled = false;
  String? failure;
  peerBackgroundChannel.setMethodCallHandler((call) async {
    if (call.method == 'cancel') {
      cancelled = true;
      peers?.cancelExchange();
    }
  });
  Timer? deadline;
  try {
    db = await AppDatabase.open();
    final repository = Repository(db);
    if (await repository.meta('peer-sync-enabled') != '1' ||
        await repository.meta('peer-background-enabled') != '1' ||
        cancelled) {
      return;
    }
    peers = PeerSyncService(
      PeerStore(repository),
      observeLifecycle: false,
      discoverAddresses: true,
      backgroundWorker: true,
    );
    await peers.initialize();
    deadline = Timer(const Duration(seconds: 100), () {
      cancelled = true;
      peers?.cancelExchange();
    });
    if (!cancelled && peers.enabled) {
      peers.journal.add(
        'Android: фоновое задание запущено. Только прогресс, заметки и статистика; новые медиа проверятся при открытии приложения.',
      );
      // Give signed LAN announcements a short opportunity to repair a changed IP.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!cancelled) await peers.syncAll(metadataOnly: true);
    }
  } catch (error) {
    failure = peerFailureDescription(error);
    peers?.recordFailure(error);
  } finally {
    deadline?.cancel();
    try {
      if (peers != null) {
        try {
          await peers.close();
        } finally {
          peers.dispose();
        }
      }
    } catch (error) {
      failure ??= peerFailureDescription(error);
    }
    try {
      await db?.close();
    } catch (error) {
      failure ??= peerFailureDescription(error);
    }
    await peerBackgroundChannel.invokeMethod<void>('done', {
      'result':
          failure ??
          (cancelled
              ? 'Фоновое задание остановлено; изменения и докачка сохранены'
              : peers?.error ?? 'Фоновое задание завершено'),
    });
  }
}
