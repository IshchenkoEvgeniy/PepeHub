/// `progress` is material duration, not a measurement of elapsed listening time.
int? audioProgressMs(Map<String, dynamic> values) {
  final unit = values['unit'];
  if (unit != null && unit != '' && unit != 'minutes' && unit != 'hours') {
    return null;
  }
  final value = num.tryParse('${values['progress']}'.replaceAll(',', '.'));
  if (value == null || !value.isFinite || value < 0 || value > 1000000000) {
    return null;
  }
  return (value * (unit == 'hours' ? 3600000 : 60000)).round();
}

Map<String, dynamic> manualAudioProgressStamp(
  Map<String, dynamic> values, {
  DateTime? at,
}) => {
  'pepehub_audio_progress_at': (at ?? DateTime.now()).toUtc().toIso8601String(),
  'pepehub_audio_progress_ms': audioProgressMs(values),
};
