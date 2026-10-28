/// Offline reading faces. Stable IDs preserve existing Lora/Onest preferences.
class ReaderFont {
  final String id, name, family;
  final bool serif;
  const ReaderFont(this.id, this.name, this.family, {this.serif = false});
}

const readerFonts = [
  ReaderFont('serif', 'Lora', 'ReaderLora', serif: true),
  ReaderFont('literata', 'Literata', 'ReaderLiterata', serif: true),
  ReaderFont('merriweather', 'Merriweather', 'ReaderMerriweather', serif: true),
  ReaderFont('noto-serif', 'Noto Serif', 'ReaderNotoSerif', serif: true),
  ReaderFont('pt-serif', 'PT Serif', 'ReaderPTSerif', serif: true),
  ReaderFont('sans', 'Onest', 'Onest'),
  ReaderFont('roboto', 'Roboto', 'ReaderRoboto'),
  ReaderFont('open-sans', 'Open Sans', 'ReaderOpenSans'),
  ReaderFont('pt-sans', 'PT Sans', 'ReaderPTSans'),
  ReaderFont('manrope', 'Manrope', 'Manrope'),
];

ReaderFont readerFont(Object? id) => readerFonts.firstWhere(
  (font) => font.id == id,
  orElse: () => readerFonts.first,
);
