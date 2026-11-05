import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'hidden_deleted_page.dart';

class LibraryTrashPage extends StatelessWidget {
  final LibraryService service;
  const LibraryTrashPage({super.key, required this.service});
  @override
  Widget build(BuildContext context) =>
      HiddenDeletedPage(library: service, initialTab: 3);
}
