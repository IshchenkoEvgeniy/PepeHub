/// Card dates use the device's local calendar. A date without a clock keeps
/// its calendar day; a timestamp with an offset represents an instant.
/// DateTime.parse normalizes overflow, so validate the written day first.
DateTime? libraryDate(Object? value) {
  if (value is DateTime) return value.toLocal();
  final text = '${value ?? ''}'.trim();
  final dotted = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(text);
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|[Tt ])').firstMatch(text);
  if (dotted == null && iso == null) return null;
  final year = int.parse(dotted?.group(3) ?? iso!.group(1)!);
  final month = int.parse(dotted?.group(2) ?? iso!.group(2)!);
  final day = int.parse(dotted?.group(1) ?? iso!.group(3)!);
  final check = DateTime.utc(year, month, day);
  if (check.year != year || check.month != month || check.day != day) {
    return null;
  }
  if (dotted != null || text.length == 10) return DateTime(year, month, day);
  final clock = RegExp(r'[Tt ](\d{2}):?(\d{2})(?::?(\d{2}))?').firstMatch(text);
  if (clock == null ||
      int.parse(clock[1]!) > 23 ||
      int.parse(clock[2]!) > 59 ||
      int.parse(clock[3] ?? '0') > 59) {
    return null;
  }
  return DateTime.tryParse(text)?.toLocal();
}
