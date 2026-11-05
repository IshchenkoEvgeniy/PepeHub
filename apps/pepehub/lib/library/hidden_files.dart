import '../data/repository.dart';

class HiddenFile {
  final String id, title;
  final bool audio;
  final int tab;
  const HiddenFile(this.id, this.title, this.audio, this.tab);
}

/// List projections only: never load track lists, file bytes or text indexes.
Future<List<HiddenFile>> hiddenFiles(Repository repository) async {
  final rows = await repository.db.customSelect('''
    SELECT b.id,json_extract(b.payload,'\$.title') AS title,
      IFNULL(json_extract(b.payload,'\$.format'),'')='audio' AS audio,
      IFNULL(h.value,'0')='1' OR IFNULL(u.value,'0')='1' AS hidden,
      IFNULL(d.value,'0')='1' AS missing,
      CASE WHEN json_extract(b.payload,'\$.format')='audio'
        THEN (EXISTS(SELECT 1 FROM audio_editions e JOIN audio_tracks t ON t.edition_id=e.id WHERE e.book_id=b.id) OR EXISTS(SELECT 1 FROM local_assets a WHERE a.book_id=b.id))
        ELSE EXISTS(SELECT 1 FROM local_assets a WHERE a.book_id=b.id) END AS has_source
    FROM records b
    LEFT JOIN metadata h ON h.key=CASE WHEN json_extract(b.payload,'\$.format')='audio' THEN 'audio-library-hidden:' ELSE 'reading-library-hidden:' END||b.id
    LEFT JOIN metadata u ON u.key=CASE WHEN json_extract(b.payload,'\$.format')='audio' THEN 'audio-user-hidden:' ELSE 'reading-user-hidden:' END||b.id
    LEFT JOIN metadata d ON d.key=CASE WHEN json_extract(b.payload,'\$.format')='audio' THEN 'audio-source-missing:' ELSE 'reading-deleted:' END||b.id
    LEFT JOIN metadata s ON s.key='audio-library-superseded:'||b.id
    WHERE b.type='book' AND b.deleted=0 AND json_valid(b.payload) AND IFNULL(s.value,'0')!='1'
    ORDER BY title,b.id
  ''').get();
  return [
    for (final row in rows)
      if (row.read<int>('missing') == 1 ||
          row.read<int>('hidden') == 1 ||
          row.read<int>('has_source') == 0)
        HiddenFile(
          row.read<String>('id'),
          row.readNullable<String>('title') ?? 'Без названия',
          row.read<int>('audio') == 1,
          row.read<int>('missing') == 1
              ? 1
              : row.read<int>('hidden') == 1
              ? 0
              : 2,
        ),
  ];
}
