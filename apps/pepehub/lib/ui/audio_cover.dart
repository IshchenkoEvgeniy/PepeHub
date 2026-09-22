import 'dart:io';

import 'package:flutter/material.dart';

import '../media/asset_store.dart';
import '../media/audio_artwork.dart';

class AudioCover extends StatefulWidget {
  final AssetStore assets;
  final String bookId;
  const AudioCover({super.key, required this.assets, required this.bookId});
  @override
  State<AudioCover> createState() => _AudioCoverState();
}

class _AudioCoverState extends State<AudioCover> {
  late Future<Uri?> image;
  @override
  void initState() {
    super.initState();
    image = ArtworkStore(widget.assets).load(widget.bookId);
  }

  @override
  void didUpdateWidget(AudioCover old) {
    super.didUpdateWidget(old);
    if (old.bookId != widget.bookId || old.assets != widget.assets) {
      image = ArtworkStore(widget.assets).load(widget.bookId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uri?>(
    future: image,
    builder: (_, snapshot) => snapshot.data == null
        ? Icon(
            Icons.headphones,
            color: Theme.of(context).colorScheme.primary,
            size: 44,
          )
        : Image.file(
            File.fromUri(snapshot.data!),
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) => const Icon(Icons.headphones),
          ),
  );
}
