import 'package:drift/drift.dart';

/// Schema version 12: growth paths, talents, eggs and the reserve of copies.
Future<void> upgradePetsSchemaV12(GeneratedDatabase db) async {
  final columns = {
    for (final row in await db.customSelect('PRAGMA table_info(pets_v1)').get())
      row.read<String>('name'),
  };
  for (final (name, type) in [
    ('path', 'TEXT'),
    ('talents', "TEXT NOT NULL DEFAULT '[]'"),
  ]) {
    if (!columns.contains(name)) {
      await db.customStatement('ALTER TABLE pets_v1 ADD COLUMN $name $type');
    }
  }
  // Eggs in the incubator. Progress = credited minutes of 'time' ledger
  // entries with id > [start_ledger]; a hatched egg keeps its row.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_eggs_v1('
    'id TEXT PRIMARY KEY,'
    'species TEXT NOT NULL,'
    'copy INTEGER NOT NULL DEFAULT 0,'
    'minutes INTEGER NOT NULL,'
    'start_ledger INTEGER NOT NULL,'
    'created_at TEXT NOT NULL,'
    'hatched_at TEXT)',
  );
  // Hatched copies waiting to be merged, per species.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_reserve_v1('
    'species TEXT PRIMARY KEY,'
    'count INTEGER NOT NULL CHECK(count>=0))',
  );
}

/// Schema version 11: shop inventory, permanent items, and pet looks.
Future<void> upgradePetsSchemaV11(GeneratedDatabase db) async {
  // Consumables: food and freezes.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_inventory_v1('
    'item_id TEXT PRIMARY KEY,'
    'count INTEGER NOT NULL CHECK(count>=0))',
  );
  // Bought once: colors, decor, accessories.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_owned_v1('
    'item_id TEXT PRIMARY KEY,'
    'bought_at TEXT NOT NULL)',
  );
  final columns = {
    for (final row in await db.customSelect('PRAGMA table_info(pets_v1)').get())
      row.read<String>('name'),
  };
  for (final (name, type) in [
    ('color', 'TEXT'),
    ('accessories', "TEXT NOT NULL DEFAULT '{}'"),
    ('fed_at', 'TEXT'),
  ]) {
    if (!columns.contains(name)) {
      await db.customStatement('ALTER TABLE pets_v1 ADD COLUMN $name $type');
    }
  }
}

/// Schema version 10: tables of the pets section. Game data never touches
/// library cards, their statuses or the PepeHub-library folder; it lives only
/// in these tables and in `metadata` keys prefixed `pets:`.
///
/// Every statement is idempotent; runs inside the migration transaction.
Future<void> createPetsSchema(GeneratedDatabase db) async {
  // Source of truth: balance = SUM(coins). [dedup] makes a recount idempotent.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_ledger_v1('
    'id INTEGER PRIMARY KEY AUTOINCREMENT,'
    'at TEXT NOT NULL,'
    'day TEXT NOT NULL,'
    'kind TEXT NOT NULL,'
    'coins INTEGER NOT NULL DEFAULT 0,'
    'xp INTEGER NOT NULL DEFAULT 0,'
    'ref TEXT,'
    'note TEXT NOT NULL DEFAULT \'\','
    'dedup TEXT NOT NULL UNIQUE)',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS pets_ledger_kind_day_v1 ON pets_ledger_v1(kind,day)',
  );
  // Experience of each ledger entry split between pets (companion 100%,
  // others 10%). Fractions are kept so many one-minute entries add up.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_xp_v1('
    'ledger_id INTEGER NOT NULL REFERENCES pets_ledger_v1(id),'
    'pet_id TEXT NOT NULL REFERENCES pets_v1(id),'
    'xp REAL NOT NULL,'
    'PRIMARY KEY(ledger_id,pet_id))',
  );
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_v1('
    'id TEXT PRIMARY KEY,'
    'species TEXT NOT NULL,'
    'name TEXT NOT NULL,'
    'created_at TEXT NOT NULL,'
    'unique_pet INTEGER NOT NULL DEFAULT 0,'
    'rank INTEGER NOT NULL DEFAULT 0)',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS pets_xp_pet_v1 ON pets_xp_v1(pet_id)',
  );
  // Counted minutes per local day since the section was enabled (streaks).
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_days_v1('
    'day TEXT PRIMARY KEY,'
    'minutes INTEGER NOT NULL)',
  );
  // Local В«finishedВ» marks, filled by triggers on the per-device records of
  // the file tabs. Library cards (LibraryRows, synced via Syncthing) are not
  // observed, so a card arriving from another device grants nothing.
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS pets_finish_queue_v1('
    'id INTEGER PRIMARY KEY AUTOINCREMENT,'
    'book_id TEXT NOT NULL,'
    'at TEXT)',
  );
  // No date known: the recount stamps it with its own clock.
  const now = 'NULL';
  const json =
      "CASE WHEN json_valid(NEW.payload) THEN NEW.payload ELSE '{}' END";
  const oldJson =
      "CASE WHEN json_valid(OLD.payload) THEN OLD.payload ELSE '{}' END";
  await db.customStatement(
    'CREATE TRIGGER IF NOT EXISTS pets_finish_book_v1 AFTER UPDATE ON records '
    "WHEN NEW.type='book' AND NEW.deleted=0 "
    "AND json_extract($json,'\$.status')='finished' "
    "AND json_extract($oldJson,'\$.status') IS NOT 'finished' BEGIN "
    'INSERT INTO pets_finish_queue_v1(book_id,at) VALUES(NEW.id,'
    "COALESCE(json_extract($json,'\$.finishedAt'),$now)); END",
  );
  const value = "CASE WHEN json_valid(NEW.value) THEN NEW.value ELSE '{}' END";
  for (final event in ['INSERT', 'UPDATE']) {
    final old = event == 'UPDATE'
        ? "CASE WHEN json_valid(OLD.value) THEN OLD.value ELSE '{}' END"
        : "'{}'";
    final e = event.toLowerCase();
    // The reader reached the end of the text.
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS pets_finish_dates_${e}_v1 AFTER $event ON metadata '
      "WHEN NEW.key LIKE 'reading-dates:%' "
      "AND json_extract($value,'\$.finishedAt') IS NOT NULL "
      "AND json_extract($old,'\$.finishedAt') IS NULL BEGIN "
      'INSERT INTO pets_finish_queue_v1(book_id,at) VALUES(substr(NEW.key,15),'
      "json_extract($value,'\$.finishedAt')); END",
    );
    // Status set by hand for a text book.
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS pets_finish_override_${e}_v1 AFTER $event ON metadata '
      "WHEN NEW.key LIKE 'reading-book:%' "
      "AND json_extract($value,'\$.overrides.status')='finished' "
      "AND json_extract($old,'\$.overrides.status') IS NOT 'finished' BEGIN "
      'INSERT INTO pets_finish_queue_v1(book_id,at) VALUES(substr(NEW.key,14),'
      "COALESCE(json_extract($value,'\$.overrides.finishedAt'),$now)); END",
    );
    // Status set by hand for an audiobook (plain text value).
    final oldAudio = event == 'UPDATE' ? 'OLD.value' : 'NULL';
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS pets_finish_audio_${e}_v1 AFTER $event ON metadata '
      "WHEN NEW.key LIKE 'audio-status-override:%' AND NEW.value='finished' "
      "AND $oldAudio IS NOT 'finished' BEGIN "
      'INSERT INTO pets_finish_queue_v1(book_id,at) VALUES(substr(NEW.key,23),'
      '$now); END',
    );
  }
}
