CREATE TABLE IF NOT EXISTS pepehub_activity_changes (
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 profile_id TEXT NOT NULL,
 entry_id TEXT NOT NULL,
 revision INTEGER NOT NULL,
 entry_json TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 UNIQUE(profile_id,operation_id),
 UNIQUE(profile_id,entry_id,revision)
);
CREATE INDEX IF NOT EXISTS pepehub_activity_profile_cursor ON pepehub_activity_changes(profile_id,sequence);
CREATE INDEX IF NOT EXISTS pepehub_activity_entry ON pepehub_activity_changes(profile_id,entry_id,revision DESC);
CREATE TABLE IF NOT EXISTS pepehub_activity_operations (
 profile_id TEXT NOT NULL,
 operation_id TEXT NOT NULL,
 operation_json TEXT NOT NULL,
 receipt_json TEXT,
 PRIMARY KEY(profile_id,operation_id)
);
