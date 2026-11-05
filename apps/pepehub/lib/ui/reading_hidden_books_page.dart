import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../library/library_service.dart';
import '../media/asset_store.dart';
import 'hidden_deleted_page.dart';

/// Compatibility entry point; all hidden/deleted screens share one implementation.
class ReadingHiddenBooksPage extends StatefulWidget {
  final AssetStore assets;
  final bool audio;
  const ReadingHiddenBooksPage({
    super.key,
    required this.assets,
    this.audio = false,
  });
  @override
  State<ReadingHiddenBooksPage> createState() => _ReadingHiddenBooksPageState();
}

class _ReadingHiddenBooksPageState extends State<ReadingHiddenBooksPage> {
  final client = http.Client();
  late final library = LibraryService(
    widget.assets.repository,
    client,
    assets: widget.assets,
  );
  @override
  void dispose() {
    library.dispose();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HiddenDeletedPage(
    library: library,
    initialMedia: widget.audio ? 'audio' : 'book',
  );
}
