import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'library_work_page.dart';

/// Library card id for a statistics book id: `card:<id>` for cards without
/// a file, otherwise the card linked to that local file. Null when the book
/// has no card (a file that was never added to the library).
String? libraryItemIdForBook(LibraryService? library, String? bookId) {
  if (library == null || bookId == null || bookId.isEmpty) return null;
  if (bookId.startsWith('card:')) return bookId.substring(5);
  for (final e in library.visibleEntries) {
    if (e.sourceBookId == bookId) return e.item.id;
  }
  return null;
}

/// Opens the card of [itemId]; null when it is not in [library] any more,
/// so a row without a card stays a plain row instead of a dead button.
VoidCallback? libraryCardOpener(
  BuildContext context,
  LibraryService? library,
  String? itemId,
) {
  if (library == null ||
      itemId == null ||
      !library.entries.any((e) => e.item.id == itemId)) {
    return null;
  }
  return () => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => LibraryWorkPage(library: library, itemId: itemId),
    ),
  );
}

/// App bar action for a per-book statistics page.
Widget? libraryCardAction(
  BuildContext context,
  LibraryService? library,
  String? bookId,
) {
  final open = libraryCardOpener(
    context,
    library,
    libraryItemIdForBook(library, bookId),
  );
  if (open == null) return null;
  return IconButton(
    key: const ValueKey('statistics-open-card'),
    tooltip: 'Открыть карточку в библиотеке',
    onPressed: open,
    icon: const Icon(Icons.auto_stories_outlined),
  );
}
