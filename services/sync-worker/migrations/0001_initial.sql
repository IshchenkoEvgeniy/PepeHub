PRAGMA foreign_keys = ON;
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  revoked_at TEXT
);
CREATE TABLE entities (
  owner_id TEXT NOT NULL,
  entity_type TEXT NOT NULL CHECK(entity_type IN ('book','session')),
  entity_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK(revision > 0),
  deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  last_operation_id TEXT NOT NULL,
  PRIMARY KEY(owner_id, entity_type, entity_id)
);
CREATE TABLE operations (
  owner_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  request_json TEXT NOT NULL,
  result_json TEXT CHECK(result_json IS NULL OR json_valid(result_json)),
  PRIMARY KEY(owner_id, operation_id)
);
CREATE TABLE change_log (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  entity_json TEXT NOT NULL CHECK(json_valid(entity_json)),
  UNIQUE(owner_id, operation_id)
);
CREATE INDEX changes_owner_sequence ON change_log(owner_id, sequence);
CREATE TABLE device_cursors (
  device_id TEXT PRIMARY KEY REFERENCES devices(id),
  sequence INTEGER NOT NULL DEFAULT 0 CHECK(sequence >= 0)
);
