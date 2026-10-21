import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'peer_models.dart';

/// Watchers are hints, never proof that a root is accessible. Callers still
/// validate the root before serving a cached index and perform safety rescans.
class PeerScanMonitor {
  final String root;
  final void Function() onChanged;
  final Set<String> invalidated = {};
  StreamSubscription<FileSystemEvent>? _watch;
  DateTime? checked;
  int generation = 0;
  bool watching = false;
  PeerScanMonitor(this.root, this.onChanged);

  void start() {
    if (root.startsWith('content:')) return;
    try {
      _watch = Directory(root)
          .watch(recursive: true)
          .listen(
            (event) {
              void changed(String path) {
                final relative = p
                    .relative(path, from: root)
                    .replaceAll('\\', '/');
                if (relative.split('/').any(peerIgnored)) return;
                invalidated.add(relative);
                generation++;
                onChanged();
              }

              changed(event.path);
              if (event is FileSystemMoveEvent && event.destination != null) {
                changed(event.destination!);
              }
            },
            onError: (Object _) {
              watching = false;
              checked = null;
              generation++;
              onChanged();
            },
            onDone: () {
              watching = false;
              checked = null;
            },
          );
      watching = true;
    } on FileSystemException {
      watching = false;
    }
  }

  bool due(DateTime now) =>
      checked == null ||
      invalidated.isNotEmpty ||
      now.difference(checked!) >= Duration(minutes: watching ? 60 : 5);
  Set<String> paths(Iterable<String> known) => {
    ...invalidated,
    for (final path in known)
      if (invalidated.any((part) => path.startsWith('$part/'))) path,
  };
  void completed(int scannedGeneration, DateTime now) {
    if (scannedGeneration == generation) {
      invalidated.clear();
      checked = now;
    }
  }

  void dirty() {
    checked = null;
    generation++;
  }

  Future<void> close() async => _watch?.cancel();
}
