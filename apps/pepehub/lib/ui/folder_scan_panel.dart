import 'package:flutter/material.dart';

import '../media/folder_scan_progress.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';

/// Live scan state with a cancel button, shared by the book and audiobook
/// folder screens.
class FolderScanPanel extends StatelessWidget {
  final FolderScanProgress progress;
  const FolderScanPanel({super.key, required this.progress});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: progress,
    builder: (context, _) {
      final palette = ShelfPalette.of(context);
      final known =
          progress.total > 0 && progress.cancellable && !progress.cancelled;
      return PepePanel(
        key: const ValueKey('folder-scan-panel'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              progress.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              progress.cancelled
                  ? 'Отменяю…'
                  : known
                  ? '${progress.doneLabel} ${progress.done} из ${progress.total} ${progress.unit}'
                  : '${progress.phase}…',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: known ? progress.done / progress.total : null,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Можно вернуться назад: проверка продолжится.',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ),
                TextButton(
                  key: const ValueKey('folder-scan-cancel'),
                  onPressed: progress.cancellable && !progress.cancelled
                      ? progress.cancel
                      : null,
                  child: const Text('Отменить'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
