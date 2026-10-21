CREATE TABLE IF NOT EXISTS pepehub_library_index (
  profile_id TEXT PRIMARY KEY,
  index_id TEXT NOT NULL,
  cursor INTEGER NOT NULL DEFAULT 0,
  schema_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pepehub_library_changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  payload_json TEXT
);
CREATE INDEX IF NOT EXISTS pepehub_library_changes_profile ON pepehub_library_changes(profile_id,sequence);
