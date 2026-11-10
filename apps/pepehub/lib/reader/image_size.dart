import 'dart:typed_data';
import 'dart:ui' show Size;

/// Pixel size read from an image header, without decoding the image.
/// Supports PNG, JPEG, GIF, WebP and BMP; returns null for anything else
/// (including SVG) and for damaged headers.
Size? imageHeaderSize(Uint8List bytes) {
  try {
    return _png(bytes) ??
        _gif(bytes) ??
        _jpeg(bytes) ??
        _webp(bytes) ??
        _bmp(bytes);
  } on RangeError {
    return null;
  }
}

Size? _valid(num width, num height) =>
    width > 0 && height > 0 && width < 100000 && height < 100000
    ? Size(width.toDouble(), height.toDouble())
    : null;

bool _starts(Uint8List b, List<int> signature, [int at = 0]) {
  if (b.length < at + signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (b[at + i] != signature[i]) return false;
  }
  return true;
}

int _be16(Uint8List b, int at) => b[at] << 8 | b[at + 1];
int _le16(Uint8List b, int at) => b[at] | b[at + 1] << 8;
int _be32(Uint8List b, int at) =>
    b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
int _le32(Uint8List b, int at) =>
    b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

Size? _png(Uint8List b) {
  if (!_starts(b, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return null;
  }
  return _valid(_be32(b, 16), _be32(b, 20));
}

Size? _gif(Uint8List b) {
  if (!_starts(b, 'GIF8'.codeUnits)) return null;
  return _valid(_le16(b, 6), _le16(b, 8));
}

Size? _jpeg(Uint8List b) {
  if (!_starts(b, const [0xff, 0xd8])) return null;
  var at = 2;
  while (at + 9 < b.length) {
    if (b[at] != 0xff) {
      at++;
      continue;
    }
    final marker = b[at + 1];
    if (marker == 0xff) {
      at++;
      continue;
    }
    // Start-of-frame markers carry the size; DHT/JPG/DAC share the range.
    if (marker >= 0xc0 &&
        marker <= 0xcf &&
        marker != 0xc4 &&
        marker != 0xc8 &&
        marker != 0xcc) {
      return _valid(_be16(b, at + 7), _be16(b, at + 5));
    }
    if (marker == 0xd8 || marker >= 0xd0 && marker <= 0xd7) {
      at += 2;
      continue;
    }
    at += 2 + _be16(b, at + 2);
  }
  return null;
}

Size? _webp(Uint8List b) {
  if (!_starts(b, 'RIFF'.codeUnits) || !_starts(b, 'WEBP'.codeUnits, 8)) {
    return null;
  }
  if (_starts(b, 'VP8X'.codeUnits, 12)) {
    final width = 1 + (b[24] | b[25] << 8 | b[26] << 16);
    final height = 1 + (b[27] | b[28] << 8 | b[29] << 16);
    return _valid(width, height);
  }
  if (_starts(b, 'VP8L'.codeUnits, 12)) {
    final bits = _le32(b, 21);
    return _valid((bits & 0x3fff) + 1, (bits >> 14 & 0x3fff) + 1);
  }
  if (_starts(b, 'VP8 '.codeUnits, 12)) {
    return _valid(_le16(b, 26) & 0x3fff, _le16(b, 28) & 0x3fff);
  }
  return null;
}

Size? _bmp(Uint8List b) {
  if (!_starts(b, 'BM'.codeUnits)) return null;
  return _valid(_le32(b, 18), _le32(b, 22).toSigned(32).abs());
}
