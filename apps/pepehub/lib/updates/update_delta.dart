import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'update_manifest.dart';

const _magic = [80, 69, 80, 69, 68, 76, 84, 49]; // PEPEDLT1

Future<String> _hash(File file, bool Function() cancelled) async =>
    (await sha256
            .bind(
              file.openRead().map((chunk) {
                if (cancelled()) {
                  throw const UpdateException('Загрузка отменена');
                }
                return chunk;
              }),
            )
            .first)
        .toString();

class _DeltaReader {
  final StreamIterator<List<int>> iterator;
  final int limit;
  final bool Function() cancelled;
  List<int> chunk = const [];
  int position = 0, fetched = 0;
  _DeltaReader(Stream<List<int>> stream, this.limit, this.cancelled)
    : iterator = StreamIterator(stream);
  Future<bool> _next() async {
    if (cancelled()) throw const UpdateException('Загрузка отменена');
    if (!await iterator.moveNext()) return false;
    chunk = iterator.current;
    position = 0;
    fetched += chunk.length;
    if (fetched > limit) {
      throw const UpdateException('Дельта-пакет превышает допустимый размер');
    }
    return true;
  }

  Future<Uint8List> take(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (position == chunk.length && !await _next()) {
        throw const UpdateException('Дельта-пакет обрезан');
      }
      final available = (chunk.length - position).clamp(0, length - written);
      result.setRange(written, written + available, chunk, position);
      position += available;
      written += available;
    }
    return result;
  }

  Future<bool> atEnd() async {
    while (position == chunk.length) {
      if (!await _next()) return true;
    }
    return false;
  }
}

/// Reconstructs the exact APK/ZIP. No executable code is read from the patch.
/// Both the base and result are bound to the signed release manifest.
Future<void> applyUpdateDelta({
  required File base,
  required File patch,
  required File output,
  required UpdateDelta delta,
  required UpdateArtifact target,
  bool Function()? cancelled,
  void Function(int bytes)? onProgress,
}) async {
  final stopped = cancelled ?? () => false;
  if (base.absolute.path == output.absolute.path ||
      patch.absolute.path == output.absolute.path) {
    throw const UpdateException('Неверный путь восстановления');
  }
  if (await FileSystemEntity.type(base.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await base.length() != delta.baseBytes ||
      await _hash(base, stopped) != delta.baseHash) {
    throw const UpdateException('Исходная версия отличается от дельта-пакета');
  }
  if (await FileSystemEntity.type(patch.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await patch.length() != delta.bytes ||
      await _hash(patch, stopped) != delta.hash) {
    throw const UpdateException('Контрольная сумма дельта-пакета не совпала');
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const UpdateException('Неверный файл восстановления');
  }
  final prefix = await patch.open();
  late int bodyOffset;
  try {
    final marker = await prefix.read(12);
    if (marker.length != 12 ||
        !List.generate(8, (i) => marker[i] == _magic[i]).every((v) => v)) {
      throw const UpdateException('Неподдерживаемый дельта-пакет');
    }
    final length = ByteData.sublistView(marker).getUint32(8, Endian.little);
    if (length < 2 || length > 4096 || length + 12 >= delta.bytes) {
      throw const UpdateException('Неверный заголовок дельта-пакета');
    }
    final raw = await prefix.read(length);
    if (raw.length != length) {
      throw const UpdateException('Заголовок дельта-пакета обрезан');
    }
    final header = jsonDecode(utf8.decode(raw)) as Map;
    if (header['version'] != 1 ||
        header['baseSha256'] != delta.baseHash ||
        header['baseBytes'] != delta.baseBytes ||
        header['targetSha256'] != target.hash ||
        header['targetBytes'] != target.bytes) {
      throw const UpdateException(
        'Дельта-пакет предназначен для другой версии',
      );
    }
    bodyOffset = length + 12;
  } finally {
    await prefix.close();
  }
  final reader = _DeltaReader(
    patch.openRead(bodyOffset).transform(gzip.decoder),
    target.bytes + (target.bytes ~/ 4096 + 2) * 13 + 1048576,
    stopped,
  );
  final source = await base.open();
  RandomAccessFile? destination;
  var written = 0, operations = 0;
  try {
    destination = await output.open(mode: FileMode.write);
    while (true) {
      if (stopped()) throw const UpdateException('Загрузка отменена');
      final command = (await reader.take(1))[0];
      if (command == 255) {
        if (written != target.bytes || !await reader.atEnd()) {
          throw const UpdateException(
            'Неверная длина восстановленного обновления',
          );
        }
        break;
      }
      if (++operations > target.bytes ~/ 4096 + 2048) {
        throw const UpdateException('Слишком много команд дельта-пакета');
      }
      if (command != 0 && command != 1) {
        throw const UpdateException('Неизвестная команда дельта-пакета');
      }
      final metadata = ByteData.sublistView(
        await reader.take(command == 0 ? 12 : 4),
      );
      final length = metadata.getUint32(command == 0 ? 8 : 0, Endian.little);
      if (length < 1 ||
          written + length > target.bytes ||
          command == 1 && length > 1048576) {
        throw const UpdateException('Некорректный блок дельта-пакета');
      }
      if (command == 0) {
        final offset = metadata.getUint64(0, Endian.little);
        if (offset < 0 ||
            length > delta.baseBytes ||
            offset > delta.baseBytes - length) {
          throw const UpdateException(
            'Копирование за пределами исходного пакета',
          );
        }
        await source.setPosition(offset);
        var remaining = length;
        while (remaining > 0) {
          if (stopped()) throw const UpdateException('Загрузка отменена');
          final bytes = await source.read(remaining.clamp(1, 65536));
          if (bytes.isEmpty) {
            throw const UpdateException('Исходный пакет изменился');
          }
          await destination.writeFrom(bytes);
          remaining -= bytes.length;
          written += bytes.length;
          onProgress?.call(written);
        }
      } else {
        await destination.writeFrom(await reader.take(length));
        written += length;
        onProgress?.call(written);
      }
    }
    await destination.flush();
  } finally {
    await destination?.close();
    await source.close();
    await reader.iterator.cancel();
  }
  if (await output.length() != target.bytes ||
      await _hash(output, stopped) != target.hash) {
    throw const UpdateException(
      'Восстановленное обновление не прошло проверку',
    );
  }
}
