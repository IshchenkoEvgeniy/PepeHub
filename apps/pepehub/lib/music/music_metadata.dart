class MusicMetadata {
  final String artist, album;
  final int? trackNumber;
  final String? coverPath;
  const MusicMetadata({
    this.artist = '',
    this.album = '',
    this.trackNumber,
    this.coverPath,
  });
  factory MusicMetadata.fromJson(Map<String, dynamic> value) => MusicMetadata(
    artist: value['artist'] as String? ?? '',
    album: value['album'] as String? ?? '',
    trackNumber: (value['trackNumber'] as num?)?.toInt(),
    coverPath: value['coverPath'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'artist': artist,
    'album': album,
    if (trackNumber != null) 'trackNumber': trackNumber,
    if (coverPath != null) 'coverPath': coverPath,
  };
  String get subtitle =>
      [if (artist.isNotEmpty) artist, if (album.isNotEmpty) album].join(' · ');
}

enum MusicRepeat { off, one, all }
