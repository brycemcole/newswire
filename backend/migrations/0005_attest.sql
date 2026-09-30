CREATE TABLE attested_devices (
  key_id TEXT PRIMARY KEY NOT NULL,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY NOT NULL,
  key_id TEXT NOT NULL REFERENCES attested_devices (key_id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_expires_at ON sessions (expires_at);
