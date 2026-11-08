import 'package:flutter/foundation.dart';

/// Thrown when the user cancels a scan. Nothing has been written yet.
class FolderScanCancelled implements Exception {
  @override
  String toString() => 'Сканирование отменено';
}

/// Live state of a folder scan for the UI: phase, checked files and whether
/// it can still be cancelled (only before the library is changed).
class FolderScanProgress extends ChangeNotifier {
  FolderScanProgress(this.title);
  String title;
  String phase = 'Поиск файлов';
  int done = 0, total = 0;

  /// How progress reads: «Проверено 340 из 1 280 файлов».
  String doneLabel = 'Проверено', unit = 'файлов';
  bool cancellable = true;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  void cancel() {
    if (!cancellable || _cancelled) return;
    _cancelled = true;
    notifyListeners();
  }

  void check() {
    if (_cancelled) throw FolderScanCancelled();
  }

  void update({
    String? title,
    String? phase,
    int? done,
    int? total,
    bool? cancellable,
    String? doneLabel,
    String? unit,
  }) {
    this.doneLabel = doneLabel ?? this.doneLabel;
    this.unit = unit ?? this.unit;
    this.title = title ?? this.title;
    this.phase = phase ?? this.phase;
    this.done = done ?? this.done;
    this.total = total ?? this.total;
    this.cancellable = cancellable ?? this.cancellable;
    notifyListeners();
  }
}

/// The scan in progress, shared so a reopened folders screen shows it and a
/// second scan cannot start in parallel. Leaving the screen does not stop it.
final activeFolderScan = ValueNotifier<FolderScanProgress?>(null);

/// How a scan ended, for a screen the user moved to while it ran.
class FolderScanOutcome {
  final String message;
  final bool failed;
  const FolderScanOutcome(this.message, {this.failed = false});
}

/// Set when a scan finishes after its folders screen was closed; the shelf
/// shows it so neither a result nor an error is lost.
final folderScanOutcome = ValueNotifier<FolderScanOutcome?>(null);
