-- Separate storage and receipts: Telegram events and its profile cursor stay untouched.
CREATE TABLE IF NOT EXISTS pepehub_library_snapshots (
  profile_id TEXT PRIMARY KEY,
  snapshot_json TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pepehub_library_operations (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  operation_json TEXT NOT NULL,
  receipt_json TEXT,
  UNIQUE(profile_id, operation_id)
);
CREATE INDEX IF NOT EXISTS pepehub_library_pending ON pepehub_library_operations(profile_id, receipt_json, sequence);
-- Fresh installations include the incremental index. Existing Companion
-- databases receive the same additive tables through migration 0014.
CREATE TABLE IF NOT EXISTS pepehub_library_index (profile_id TEXT PRIMARY KEY,index_id TEXT NOT NULL,cursor INTEGER NOT NULL DEFAULT 0,schema_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS pepehub_library_changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT,profile_id TEXT NOT NULL,item_id TEXT NOT NULL,payload_json TEXT);
CREATE INDEX IF NOT EXISTS pepehub_library_changes_profile ON pepehub_library_changes(profile_id,sequence);
