import 'app_sync_models.dart';
import 'peer_models.dart';

void validateAppSyncData(AppSyncVersion version) {
  final data = version.value;
  if (data == null) return;
  void require(bool value) {
    if (!value) throw const FormatException('Некорректные данные приложения');
  }

  bool integer(Object? value, [int maximum = 9007199254740991]) =>
      value is int && value >= 0 && value <= maximum;
  bool text(Object? value, int maximum, {bool empty = false}) =>
      value is String &&
      (empty || value.trim().isNotEmpty) &&
      value.length <= maximum;
  bool id(Object? value) => value is String && appSyncUuid.hasMatch(value);
  bool hash(Object? value) => value is String && appSyncHash.hasMatch(value);
  void source(Map value) {
    require(
      hash(value['hash']) &&
          integer(value['bytes'], 1 << 50) &&
          text(value['name'], 1000),
    );
    require(
      value.keys.every(
        {'hash', 'bytes', 'name', 'folder', 'path', 'id'}.contains,
      ),
    );
    if (value.containsKey('folder') || value.containsKey('path')) {
      require(id(value['folder']) && value['path'] is String);
      peerPath(value['path'] as String);
    }
  }

  final key = version.key;
  if (key.startsWith('media:')) {
    final kind = key.split(':')[1];
    if (kind == 'item') {
      require(
        ['video', 'course'].contains(data['kind']) &&
            text(data['title'], 300) &&
            data['favorite'] is bool,
      );
      require(data.keys.every({'kind', 'title', 'favorite'}.contains));
    } else if (kind == 'lesson') {
      require(
        id(data['itemId']) &&
            text(data['title'], 300) &&
            text(data['module'], 1000, empty: true) &&
            integer(data['ordinal'], 10000) &&
            hash(data['mediaVersion']),
      );
      require(data['source'] is Map);
      source(data['source'] as Map);
      require((data['source'] as Map)['hash'] == data['mediaVersion']);
      require(
        data.keys.every(
          {
            'itemId',
            'title',
            'module',
            'ordinal',
            'mediaVersion',
            'source',
          }.contains,
        ),
      );
    } else {
      require(
        ['book', 'audio'].contains(data['kind']) &&
            text(data['format'], 30) &&
            hash(data['manifest']) &&
            data['sources'] is List,
      );
      final values = data['sources'] as List;
      require(
        values.isNotEmpty &&
            values.length <= 1000 &&
            (data['kind'] == 'audio' || values.length == 1),
      );
      final ids = <String>{};
      for (final value in values) {
        require(value is Map);
        source(value as Map);
        if (data['kind'] == 'audio') {
          require(id(value['id']) && ids.add(value['id'] as String));
        }
      }
      require(
        appSyncDigest(values.map((e) => (e as Map)['hash']).toList()) ==
            data['manifest'],
      );
      require(
        data.keys.every({'kind', 'format', 'manifest', 'sources'}.contains),
      );
    }
  } else if (key.startsWith('position:')) {
    if (key.startsWith('position:reader:')) {
      require(
        integer(data['chapter'], 1000000) &&
            integer(data['textOffset'], 1 << 40),
      );
      require(!data.containsKey('pdfFinished') || data['pdfFinished'] is bool);
    } else {
      final speed = data['speed'];
      require(
        integer(data['positionMs']) &&
            speed is num &&
            speed.isFinite &&
            speed >= .5 &&
            speed <= 3,
      );
      if (key.startsWith('position:video:')) {
        require(
          data['lessonId'] == key.split(':')[2] &&
              data['mediaVersion'] == key.split(':')[3],
        );
      } else {
        require(id(data['trackId']));
      }
    }
  } else if (key.startsWith('meta:reading-coverage:')) {
    require(data['ranges'] is List);
    for (final value in data['ranges'] as List) {
      require(
        value is List &&
            value.length == 2 &&
            integer(value[0], 1 << 40) &&
            integer(value[1], 1 << 40) &&
            (value[1] as int) >= (value[0] as int),
      );
    }
  } else if (key.startsWith('meta:reading-session:')) {
    require(
      id(data['bookId']) &&
          hash(data['hash']) &&
          data['id'] == key.substring('meta:reading-session:'.length),
    );
    require(
      integer(data['position']) &&
          integer(data['length']) &&
          data['spans'] is List &&
          data['events'] is List,
    );
    for (final value in data['spans'] as List) {
      require(value is Map);
      final span = value as Map;
      final start = DateTime.tryParse('${span['start']}'),
          end = DateTime.tryParse('${span['end']}');
      require(start != null && end != null && !end.isBefore(start));
      for (final field in ['newChars', 'repeatChars', 'activeMs']) {
        if (span.containsKey(field)) require(integer(span[field]));
      }
    }
  } else if (key.startsWith('record:audio_event:')) {
    require(
      id(data['bookId']) &&
          data['kind'] is String &&
          DateTime.tryParse('${data['at']}') != null,
    );
    for (final field in ['positionMs', 'endMs', 'wallMs', 'mediaMs']) {
      if (data.containsKey(field)) require(integer(data[field]));
    }
    if (data['kind'] == 'listen') {
      require(
        (data['wallMs'] as int) > 0 &&
            (data['endMs'] as int) > (data['positionMs'] as int),
      );
    }
  } else if (key == 'meta:reading-daily-goal') {
    require(integer(data['setting'], 1440));
  } else if (key == 'meta:audio-listening-goals') {
    require(data['setting'] is Map);
    final value = data['setting'] as Map;
    require(
      integer(value['dailyMinutes'], 1440) &&
          integer(value['weeklyMinutes'], 10080),
    );
  }
}
